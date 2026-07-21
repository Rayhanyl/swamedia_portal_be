import ballerina/http;
import ballerina/log;
import rayha/swamedia_portal_be.config;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.services;
import rayha/swamedia_portal_be.utils;

listener http:Listener apiListener = new (config:port);

# Rejects any Bearer token already invalidated via `/api/v1/auth/revoke` or
# `/api/v1/auth/logout` (see `utils:denylistToken`/`utils:isTokenDenylisted`), before
# Ballerina's declarative JWKS auth on each service even runs. Ballerina only lets
# interceptors be engaged per-service (a `public function createInterceptors()` method,
# structurally satisfying `http:InterceptableService`), not once for the whole listener —
# so every JWKS-protected `service` block below adds
# `public function createInterceptors() => [tokenDenylistInterceptor];` to pick this up.
#
# Also enforces portal group membership here via `services:verifyAppGroupMembership` (a live,
# Redis-cached `userInfo` lookup) instead of the declarative JWKS `scopes` check that used to sit
# in every service's `@http:ServiceConfig.auth` block. That check validated `swaportal_group_id`
# straight off the access token's own embedded claims, which WSO2 IS has been observed to
# intermittently omit at token issuance — the same user, same login flow, sometimes gets an access
# token carrying the claim and sometimes doesn't, causing every business endpoint to 403 at random
# even though the id_token/userinfo claim is reliably present. See documentation/note/Auth-Redis-DB.md
# §1.4 for the incident history.
service class TokenDenylistInterceptor {
    *http:RequestInterceptor;

    resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|http:Response|error? {
        string|http:HeaderNotFoundError authHeader = req.getHeader("Authorization");
        if authHeader is string && authHeader.startsWith("Bearer ") {
            string token = authHeader.substring(7).trim();
            if token.length() > 0 {
                if utils:isTokenDenylisted(token) {
                    return errorToResponse(utils:unauthorizedError("Token sudah tidak berlaku, silakan login kembali"));
                }
                models:AppError? groupGate = services:verifyAppGroupMembership(token);
                if groupGate is models:AppError {
                    return errorToResponse(groupGate);
                }
            }
        }
        return ctx.next();
    }
}

final TokenDenylistInterceptor tokenDenylistInterceptor = new;

# Per-service RBAC gate (the enforcement half of the role/permission admin screens). Runs after
# TokenDenylistInterceptor: it reads the caller's role from their cached userinfo, looks up that
# role's permission matrix (Redis `role:{id}:permissions`, per schema note #7) and returns 403
# unless the role holds the CRUD/approve/export bit this request needs on `modulKode` — all in
# `services:requirePermission`. Every gated service adds one to its createInterceptors() list, e.g.
# `[tokenDenylistInterceptor, new PermissionInterceptor("KARYAWAN")]`.
#
# The HTTP method (plus a couple of path keywords) picks the action: POST=create, PUT/PATCH=update,
# DELETE=delete, else read; a path segment `approve`/`reject` maps to approve, `export` to export.
# A service that hosts a sub-resource belonging to a *different* modul (e.g. pencairan nested under
# tagihan) passes `subResourceModul` mapping that path segment to the sub-resource's modul code.
#
# NOTE: this is intentionally NOT an `isolated` class — `services:requirePermission` performs
# (non-isolated) Redis/DB/userinfo lookups. Its fields are set once at service init and only read
# thereafter, mirroring the plain `service class` style of TokenDenylistInterceptor above.
service class PermissionInterceptor {
    *http:RequestInterceptor;
    private final string modulKode;
    private final map<string> subResourceModul;

    function init(string modulKode, map<string> subResourceModul = {}) {
        self.modulKode = modulKode;
        self.subResourceModul = subResourceModul;
    }

    resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|http:Response|error? {
        if req.method == "OPTIONS" {
            return ctx.next(); // CORS preflight carries no auth
        }
        string|http:HeaderNotFoundError authHeader = req.getHeader("Authorization");
        if authHeader !is string || !authHeader.startsWith("Bearer ") {
            return ctx.next(); // let the declarative JWKS auth issue the 401
        }
        string token = authHeader.substring(7).trim();

        string modul = self.modulKode;
        foreach string segment in path {
            string? override = self.subResourceModul[segment];
            if override is string {
                modul = override;
                break;
            }
        }

        models:AppError|error? gate = services:requirePermission(token, modul, resolveAction(req.method, path));
        if gate is models:AppError {
            return errorToResponse(gate);
        }
        if gate is error {
            log:printError("permission check failed", gate);
            return errorToResponse(utils:internalError("Gagal memeriksa perizinan"));
        }
        return ctx.next();
    }
}

# Derives the required permission action from the HTTP method and path. Path keywords win over the
# method: an `approve`/`reject` segment needs can_approve, an `export` segment needs can_export;
# otherwise POST=create, PUT/PATCH=update, DELETE=delete, and everything else (GET/HEAD) = read.
#
# + method - the request's HTTP method
# + path - the path segments after the service base
# + return - the action verb (create / read / update / delete / approve / export)
isolated function resolveAction(string method, string[] path) returns string {
    foreach string segment in path {
        if segment == "approve" || segment == "reject" {
            return "approve";
        }
        if segment == "export" {
            return "export";
        }
    }
    match method {
        "POST" => {
            return "create";
        }
        "PUT"|"PATCH" => {
            return "update";
        }
        "DELETE" => {
            return "delete";
        }
    }
    return "read";
}

# BFF facade over WSO2 Identity Server. The frontend only ever talks to these endpoints;
# all IS URLs, client credentials, flowIds and authorization codes stay inside the backend.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    }
}
service /api/v1/auth on apiListener {

    # Starts the authentication flow (wraps IS /oauth2/authorize). Returns a flowId and the
    # authenticators the IS offers. Optional — the frontend can just call `login` instead.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post init() returns http:Response {
        models:InitResponse|models:AppError result = services:initFlow();
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse(result, "Flow autentikasi berhasil dimulai");
    }

    # Logs a user in with username/password, running init -> authenticate -> token exchange
    # against IS server-side and returning the full token set + decoded user.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post login(@http:Payload models:LoginRequest payload) returns http:Response {
        models:LoginResponse|models:AppError result = services:login(payload);
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse(result, "Login berhasil");
    }

    # Exchanges an authorization code for tokens (wraps IS /oauth2/token, authorization_code grant).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post token(@http:Payload models:TokenExchangeRequest payload) returns http:Response {
        models:LoginResponse|models:AppError result = services:exchangeToken(payload.code);
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse(result, "Token berhasil diambil");
    }

    # Refreshes an expired access token (wraps IS /oauth2/token, refresh_token grant).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post refresh(@http:Payload models:RefreshRequest payload) returns http:Response {
        models:LoginResponse|models:AppError result = services:refresh(payload);
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse(result, "Token berhasil diperbarui");
    }

    # Returns the OIDC user claims for the access token in the Authorization header
    # (wraps IS /oauth2/userinfo).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get userinfo(@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        string|models:AppError token = utils:bearerToken(authorization);
        if token is models:AppError {
            return errorToResponse(token);
        }

        map<json>|models:AppError result = services:userInfo(token);
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse(result, "Userinfo berhasil diambil");
    }

    # Introspects a token (wraps IS /oauth2/introspect).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post introspect(@http:Payload models:IntrospectRequest payload) returns http:Response {
        models:IntrospectResponse|models:AppError result = services:introspect(payload);
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse(result, "Introspeksi token berhasil");
    }

    # Revokes an access or refresh token (wraps IS /oauth2/revoke).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post revoke(@http:Payload models:RevokeRequest payload) returns http:Response {
        models:AppError? result = services:revoke(payload);
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse((), "Token berhasil dicabut");
    }

    # Ends the user's session on WSO2 IS (wraps IS /oidc/logout).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post logout(@http:Payload models:LogoutRequest payload) returns http:Response {
        models:AppError? result = services:logout(payload);
        if result is models:AppError {
            return errorToResponse(result);
        }
        return okResponse((), "Logout berhasil");
    }
}

# Dashboard summary — public, pre-login. No `auth` guard: the frontend calls this before the
# user has a token (e.g. on the login screen), so it must stay outside the JWKS-protected block.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "OPTIONS"],
        allowHeaders: ["Content-Type"],
        allowCredentials: true,
        maxAge: 3600
    }
}
service /api/v1/dashboard on apiListener {

    # GET /api/v1/dashboard/summary — Total Proyek, Revenue Bulan Ini, Proyek Sedang Dikerjakan.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get summary() returns http:Response {
        do {
            models:DashboardSummary summary = check services:getDashboardSummary();
            return successHttp(http:STATUS_OK, summary, "Ringkasan dashboard berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get dashboard summary");
        }
    }
}

# Demo endpoint proving the JWKS-based access token guard below. Every future business
# service should copy both the @http:ServiceConfig block and the createInterceptors()
# line onto its own service declaration (referencing the same
# config:jwtIssuer/config:clientId/config:jwksUrl) to get the same protection:
# Ballerina verifies the Bearer access token's signature (via WSO2's JWKS), expiry, issuer
# and audience on every request, and auto-returns 401 before the resource function runs if
# any check fails — no manual validation code needed per endpoint. The createInterceptors()
# hook additionally runs TokenDenylistInterceptor first, so a token already invalidated via
# /api/v1/auth/revoke or /api/v1/auth/logout is rejected even before that JWKS check.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business on apiListener {
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # Returns 200 only if the caller's Bearer access token passed JWKS validation.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get ping() returns http:Response {
        return okResponse((), "Token valid, akses diizinkan");
    }
}

# Master Data — Unit CRUD. Same JWKS-based access token guard as /api/v1/business.
# Every response (success and error) is wrapped in the standard `ApiResponse` envelope,
# and every resource uses the `do { ... } on fail error err { ... }` pattern: domain
# failures surface as `models:AppError` (mapped to their own status/code by `errorHttp`),
# and anything else becomes a generic 500.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/units on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("UNIT_ORGANISASI")];

    # GET /api/v1/master/units — paginated list with optional search/status/parent filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, string? status, int? parent_id, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:UnitListResult result = check services:getUnits(search, status, parent_id, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar unit berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get units");
        }
    }

    # GET /api/v1/master/units/tree — full unit hierarchy (nested children), no pagination.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get tree() returns http:Response {
        do {
            models:UnitTreeNode[] tree = check services:getUnitTree();
            return successHttp(http:STATUS_OK, tree, "Hierarki unit berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get unit tree");
        }
    }

    # GET /api/v1/master/units/{id} — single unit detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Unit unit = check services:getUnitById(id);
            return successHttp(http:STATUS_OK, unit, "Detail unit berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get unit detail");
        }
    }

    # POST /api/v1/master/units — create a unit. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UnitCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Unit created = check services:createUnit(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Unit berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create unit");
        }
    }

    # PUT /api/v1/master/units/{id} — update a unit. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UnitUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Unit updated = check services:updateUnit(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Unit berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update unit");
        }
    }

    # DELETE /api/v1/master/units/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteUnit(id, subject);
            return successHttp(http:STATUS_OK, (), "Unit berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete unit");
        }
    }
}

# Master Data — Industri CRUD. Same JWKS-based access token guard and response conventions
# as /api/v1/master/units (envelope + `do { ... } on fail` + shared successHttp/errorHttp).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/industries on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("INDUSTRI")];

    # GET /api/v1/master/industries — paginated list with optional search over kode/nama.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:IndustriListResult result = check services:getIndustries(search, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar industri berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get industries");
        }
    }

    # GET /api/v1/master/industries/{id} — single industri detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Industri industri = check services:getIndustriById(id);
            return successHttp(http:STATUS_OK, industri, "Detail industri berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get industri detail");
        }
    }

    # POST /api/v1/master/industries — create an industri. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:IndustriCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Industri created = check services:createIndustri(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Industri berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create industri");
        }
    }

    # PUT /api/v1/master/industries/{id} — update an industri. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:IndustriUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Industri updated = check services:updateIndustri(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Industri berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update industri");
        }
    }

    # DELETE /api/v1/master/industries/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteIndustri(id, subject);
            return successHttp(http:STATUS_OK, (), "Industri berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete industri");
        }
    }
}

# Master Data — Tags CRUD (labels for Proyek). Same guard/conventions as the other master
# services (envelope + `do { ... } on fail` + shared successHttp/errorHttp).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/tags on apiListener {
    // Not RBAC-gated: `tags` is shared reference data (the proyek tag master) with no dedicated
    // `modul` row — every authenticated user may read/manage it. See README (Middleware) for the
    // list of ungated services and the rationale.
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/master/tags — paginated list, optional search (kode/nama) and unit_id filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? unit_id, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:TagsListResult result = check services:getTags(search, unit_id, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar tag berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get tags");
        }
    }

    # GET /api/v1/master/tags/{id} — single tag detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Tags tag = check services:getTagsById(id);
            return successHttp(http:STATUS_OK, tag, "Detail tag berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get tag detail");
        }
    }

    # POST /api/v1/master/tags — create a tag. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TagsCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Tags created = check services:createTags(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Tag berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create tag");
        }
    }

    # PUT /api/v1/master/tags/{id} — update a tag. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TagsUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Tags updated = check services:updateTags(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Tag berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update tag");
        }
    }

    # DELETE /api/v1/master/tags/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteTags(id, subject);
            return successHttp(http:STATUS_OK, (), "Tag berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete tag");
        }
    }
}

# Master Data — Resource Tags CRUD (labels for Resource Unit). Adds a `status` filter on top
# of the Tags endpoints. Same guard/conventions as the other master services.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/resource\-tags on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("RESOURCE_TAG")];

    # GET /api/v1/master/resource-tags — paginated list, optional search/unit_id/status filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? unit_id, string? status, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:ResourceTagsListResult result =
                check services:getResourceTags(search, unit_id, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar resource tag berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get resource tags");
        }
    }

    # GET /api/v1/master/resource-tags/{id} — single resource tag detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:ResourceTags tag = check services:getResourceTagsById(id);
            return successHttp(http:STATUS_OK, tag, "Detail resource tag berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get resource tag detail");
        }
    }

    # POST /api/v1/master/resource-tags — create. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ResourceTagsCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:ResourceTags created = check services:createResourceTags(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Resource tag berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create resource tag");
        }
    }

    # PUT /api/v1/master/resource-tags/{id} — update. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ResourceTagsUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:ResourceTags updated = check services:updateResourceTags(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Resource tag berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update resource tag");
        }
    }

    # DELETE /api/v1/master/resource-tags/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteResourceTags(id, subject);
            return successHttp(http:STATUS_OK, (), "Resource tag berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete resource tag");
        }
    }
}

# Master Data — Kategori Surat CRUD (letter-category master, DR-01..DR-09). Same guard/
# conventions as the other master services. `is_default` is read-only (never accepted from
# create/update bodies).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/kategori\-surat on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("KATEGORI_SURAT")];

    # GET /api/v1/master/kategori-surat — paginated list, optional search over kode/nama + status filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, string? status, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:KategoriSuratListResult result = check services:getKategoriSurat(search, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar kategori surat berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get kategori surat");
        }
    }

    # GET /api/v1/master/kategori-surat/{id} — single kategori surat detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:KategoriSurat kategori = check services:getKategoriSuratById(id);
            return successHttp(http:STATUS_OK, kategori, "Detail kategori surat berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get kategori surat detail");
        }
    }

    # POST /api/v1/master/kategori-surat — create (always non-default). created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KategoriSuratCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KategoriSurat created = check services:createKategoriSurat(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Kategori surat berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create kategori surat");
        }
    }

    # PUT /api/v1/master/kategori-surat/{id} — update (is_default untouched). updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KategoriSuratUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KategoriSurat updated = check services:updateKategoriSurat(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Kategori surat berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update kategori surat");
        }
    }

    # DELETE /api/v1/master/kategori-surat/{id} — hard delete.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id]() returns http:Response {
        do {
            check services:deleteKategoriSurat(id);
            return successHttp(http:STATUS_OK, (), "Kategori surat berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete kategori surat");
        }
    }
}

# RBAC — Role CRUD. `role` has no is_deleted column: delete is a hard delete that cascades
# cleanup of the role's role_permission/role_menu rows (see role_repository/role_service).
# Same guard/conventions as the other master services.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/roles on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("ROLE_PERMISSION")];

    # GET /api/v1/master/roles — paginated list, optional search over kode/nama + status filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, string? status, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:RoleListResult result = check services:getRoles(search, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar role berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get roles");
        }
    }

    # GET /api/v1/master/roles/{id} — single role detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Role role = check services:getRoleById(id);
            return successHttp(http:STATUS_OK, role, "Detail role berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get role detail");
        }
    }

    # POST /api/v1/master/roles — create a role. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:RoleCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Role created = check services:createRole(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Role berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create role");
        }
    }

    # PUT /api/v1/master/roles/{id} — update a role. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:RoleUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Role updated = check services:updateRole(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Role berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update role");
        }
    }

    # DELETE /api/v1/master/roles/{id} — hard delete (cascades role_permission/role_menu cleanup).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id]() returns http:Response {
        do {
            check services:deleteRole(id);
            return successHttp(http:STATUS_OK, (), "Role berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete role");
        }
    }
}

# RBAC — Menu CRUD (navigation tree). `menu` has no audit columns/is_deleted: create/update/
# delete are plain hard operations. Same guard/conventions as the other master services.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/menu on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("ROLE_PERMISSION")];

    # GET /api/v1/master/menu/tree — full menu hierarchy (nested children), no pagination.
    # Declared before `.`/`[int id]` for the same routing-precedence reason as
    # `/api/v1/master/units/tree`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get tree() returns http:Response {
        do {
            models:MenuTreeNode[] tree = check services:getMenuTree();
            return successHttp(http:STATUS_OK, tree, "Hierarki menu berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get menu tree");
        }
    }

    # GET /api/v1/master/menu — paginated flat list with optional search/status/parent filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, string? status, int? parent_id, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:MenuListResult result = check services:getMenus(search, status, parent_id, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar menu berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get menu");
        }
    }

    # GET /api/v1/master/menu/{id} — single menu detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Menu menu = check services:getMenuById(id);
            return successHttp(http:STATUS_OK, menu, "Detail menu berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get menu detail");
        }
    }

    # POST /api/v1/master/menu — create a menu node.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Payload models:MenuCreateRequest payload) returns http:Response {
        do {
            models:Menu created = check services:createMenu(payload);
            return successHttp(http:STATUS_CREATED, created, "Menu berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create menu");
        }
    }

    # PUT /api/v1/master/menu/{id} — update a menu node.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Payload models:MenuUpdateRequest payload) returns http:Response {
        do {
            models:Menu updated = check services:updateMenu(id, payload);
            return successHttp(http:STATUS_OK, updated, "Menu berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update menu");
        }
    }

    # DELETE /api/v1/master/menu/{id} — hard delete; blocked while active sub-menu exist.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id]() returns http:Response {
        do {
            check services:deleteMenu(id);
            return successHttp(http:STATUS_OK, (), "Menu berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete menu");
        }
    }
}

# RBAC — Modul. Read-only fixed master list (A13 in the schema) that role_permission matrices
# are keyed against. No create/update/delete endpoint.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/modul on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("ROLE_PERMISSION")];

    # GET /api/v1/master/modul — flat list ordered by urutan, no pagination.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .() returns http:Response {
        do {
            models:Modul[] modul = check services:getModul();
            return successHttp(http:STATUS_OK, modul, "Daftar modul berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get modul");
        }
    }
}

# RBAC — Role Permission matrix. Edited as a whole per role (A14 in the schema): GET returns
# every modul with this role's grants (or all-false/scope ALL defaults), PUT replaces the
# entire matrix in one shot. Saving invalidates the `role:{id}:permissions` Redis key the auth
# middleware reads (schema implementation note #7).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "PUT", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/role\-permissions on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("ROLE_PERMISSION")];

    # GET /api/v1/master/role-permissions/{roleId} — the role's full permission matrix.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int roleId]() returns http:Response {
        do {
            models:RolePermissionMatrix matrix = check services:getRolePermissions(roleId);
            return successHttp(http:STATUS_OK, matrix, "Matriks permission role berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get role permissions");
        }
    }

    # PUT /api/v1/master/role-permissions/{roleId} — replace the role's entire permission
    # matrix. created_by on every row comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int roleId](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:RolePermissionUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:RolePermissionMatrix matrix = check services:replaceRolePermissions(roleId, payload, subject);
            return successHttp(http:STATUS_OK, matrix, "Matriks permission role berhasil disimpan");
        } on fail error err {
            return errorHttp(err, "Failed to save role permissions");
        }
    }
}

# RBAC — Role Menu assignment. Edited as a whole per role, independent of role_permission
# (A16 in the schema): GET returns the full menu tree with an `assigned` flag per node, PUT
# replaces the entire assigned set in one shot. Saving invalidates the `role:{id}:menu` Redis
# key the auth middleware reads (schema implementation note #7).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "PUT", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/role\-menus on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("ROLE_PERMISSION")];

    # GET /api/v1/master/role-menus/{roleId} — the role's full menu tree with assigned flags.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int roleId]() returns http:Response {
        do {
            models:RoleMenuMatrix matrix = check services:getRoleMenus(roleId);
            return successHttp(http:STATUS_OK, matrix, "Menu role berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get role menus");
        }
    }

    # PUT /api/v1/master/role-menus/{roleId} — replace the role's entire assigned-menu set.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int roleId](@http:Payload models:RoleMenuUpdateRequest payload) returns http:Response {
        do {
            models:RoleMenuMatrix matrix = check services:replaceRoleMenus(roleId, payload);
            return successHttp(http:STATUS_OK, matrix, "Menu role berhasil disimpan");
        } on fail error err {
            return errorHttp(err, "Failed to save role menus");
        }
    }
}

# Master Data — Jabatan (jabatan_master). Read-only: sole purpose is the dropdown source for
# the Karyawan Tambah/Ubah form (karyawan.jabatan_id FK). No create/update/delete endpoints.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/jabatan on apiListener {
    // Not RBAC-gated: read-only jabatan reference data feeding the Karyawan form, with no dedicated
    // `modul` row. See README (Middleware) for the ungated-services rationale.
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/master/jabatan — flat list (dropdown source), not paginated. status defaults
    # to AKTIF-only when omitted.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, string? status) returns http:Response {
        do {
            models:JabatanMaster[] jabatan = check services:getJabatan(search, status);
            return successHttp(http:STATUS_OK, jabatan, "Daftar jabatan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get jabatan");
        }
    }
}

# Master Data — Karyawan CRUD (the most FK-referenced master). Same guard/conventions as the
# other master services. subject_id is accepted on create/update but only ever returned in the
# by-id detail response (list omits it) — see karyawan_service for the security rationale.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/karyawan on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("KARYAWAN")];

    # GET /api/v1/master/karyawan/dropdown — lightweight {id, nama, unitNama} projection, no
    # pagination. Literal path registered before the list `.`/`[int id]` resources, mirroring
    # the `/api/v1/master/units/tree` precedent.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get dropdown(int? unit_id, string? status, string? search) returns http:Response {
        do {
            models:KaryawanDropdownItem[] items = check services:getKaryawanDropdown(unit_id, status, search);
            return successHttp(http:STATUS_OK, items, "Dropdown karyawan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get karyawan dropdown");
        }
    }

    # GET /api/v1/master/karyawan — paginated list (no subject_id), optional search/unit/status filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? unit_id, string? status, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:KaryawanListResult result = check services:getKaryawan(search, unit_id, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar karyawan berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get karyawan");
        }
    }

    # GET /api/v1/master/karyawan/{id} — single karyawan detail (includes subject_id).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:KaryawanDetail karyawan = check services:getKaryawanById(id);
            return successHttp(http:STATUS_OK, karyawan, "Detail karyawan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get karyawan detail");
        }
    }

    # POST /api/v1/master/karyawan — create. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KaryawanCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KaryawanDetail created = check services:createKaryawan(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Karyawan berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create karyawan");
        }
    }

    # PUT /api/v1/master/karyawan/{id} — update. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KaryawanUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KaryawanDetail updated = check services:updateKaryawan(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Karyawan berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update karyawan");
        }
    }

    # DELETE /api/v1/master/karyawan/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteKaryawan(id, subject);
            return successHttp(http:STATUS_OK, (), "Karyawan berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete karyawan");
        }
    }
}

# Master Data — Customer CRUD. Depends on the karyawan (am_id) and industri (industri_id)
# masters. Same guard/conventions as the other master services; the by-id detail response
# includes joined amNama/industriNama.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/customers on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("CUSTOMER")];

    # GET /api/v1/master/customers — paginated list, optional search + am/industri/status/jenis filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? am_id, int? industri_id, string? status_peluang,
            string? jenis_customer, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:CustomerListResult result =
                check services:getCustomers(search, am_id, industri_id, status_peluang, jenis_customer, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar customer berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get customers");
        }
    }

    # GET /api/v1/master/customers/{id} — single customer detail (with amNama/industriNama).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:CustomerDetail customer = check services:getCustomerById(id);
            return successHttp(http:STATUS_OK, customer, "Detail customer berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get customer detail");
        }
    }

    # POST /api/v1/master/customers — create. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:CustomerCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:CustomerDetail created = check services:createCustomer(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Customer berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create customer");
        }
    }

    # PUT /api/v1/master/customers/{id} — update. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:CustomerUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:CustomerDetail updated = check services:updateCustomer(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Customer berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update customer");
        }
    }

    # DELETE /api/v1/master/customers/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteCustomer(id, subject);
            return successHttp(http:STATUS_OK, (), "Customer berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete customer");
        }
    }
}

# Master Data — Contact CRUD (contacts belonging to a customer). Same guard/conventions as the
# other master services. `tipe_kontak` is the contact ROLE (UTAMA/AKTIF/PROSPEK), not a status.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/contacts on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("CONTACT")];

    # GET /api/v1/master/contacts — paginated list, optional customer_id/search/tipe_kontak filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(int? customer_id, string? search, string? tipe_kontak, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:ContactListResult result =
                check services:getContacts(customer_id, search, tipe_kontak, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar contact berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get contacts");
        }
    }

    # GET /api/v1/master/contacts/{id} — single contact detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Contact contact = check services:getContactById(id);
            return successHttp(http:STATUS_OK, contact, "Detail contact berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get contact detail");
        }
    }

    # POST /api/v1/master/contacts — create. created_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ContactCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Contact created = check services:createContact(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Contact berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create contact");
        }
    }

    # PUT /api/v1/master/contacts/{id} — update. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ContactUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Contact updated = check services:updateContact(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Contact berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update contact");
        }
    }

    # DELETE /api/v1/master/contacts/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteContact(id, subject);
            return successHttp(http:STATUS_OK, (), "Contact berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete contact");
        }
    }
}

# e-Office — Daftar Surat (nomor_surat) CRUD. "Daftar Surat" is the UI menu name; the table and
# technical types keep the nomor_surat/NomorSurat naming. Same JWKS-based access token guard and
# response conventions as the master services. The `nomor` field is fully server-generated on
# create (never accepted from the body); on update, kategori_surat_id/tahun/urutan/nomor are
# immutable (silently ignored if sent).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/daftar\-surat on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("DAFTAR_SURAT")];

    # GET /api/v1/business/daftar-surat — paginated list. Optional search (nomor/tujuan/perihal)
    # and tahun/kategori_surat_id/proyek_id filters; tahun defaults to the current year. By default
    # only active letters are returned; ?include_dibatalkan=true also surfaces cancelled ones
    # (for Admin/Direksi audit/report views) with alasanPembatalan/isDibatalkan filled in.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? tahun, int? kategori_surat_id, int? proyek_id,
            boolean include_dibatalkan = false, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:NomorSuratListResult result = check services:getNomorSuratList(
                    search, tahun, kategori_surat_id, proyek_id, include_dibatalkan, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar surat berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get daftar surat");
        }
    }

    # GET /api/v1/business/daftar-surat/preview-nomor — read-only preview of the next number for a
    # (kategori_surat_id, tanggal) combo. Reserves nothing; the value may change if another create
    # commits first. Declared before the {id} resource for readability (routing prefers this literal
    # segment over the int path param regardless of order).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get preview\-nomor(int? kategori_surat_id, string? tanggal) returns http:Response {
        do {
            models:NomorSuratPreview preview = check services:previewNomor(kategori_surat_id, tanggal);
            return successHttp(http:STATUS_OK, preview, "Preview nomor surat");
        } on fail error err {
            return errorHttp(err, "Failed to preview nomor surat");
        }
    }

    # GET /api/v1/business/daftar-surat/{id} — single letter detail (with joined kategori/proyek names).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:NomorSurat surat = check services:getNomorSuratById(id);
            return successHttp(http:STATUS_OK, surat, "Detail surat berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get surat detail");
        }
    }

    # POST /api/v1/business/daftar-surat — create with auto-generated nomor. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:NomorSuratCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:NomorSurat created = check services:createNomorSurat(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Surat berhasil ditambahkan");
        } on fail error err {
            return errorHttp(err, "Failed to create surat");
        }
    }

    # PUT /api/v1/business/daftar-surat/{id} — update mutable fields only. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:NomorSuratUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:NomorSurat updated = check services:updateNomorSurat(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Surat berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update surat");
        }
    }

    # DELETE /api/v1/business/daftar-surat/{id} — cancellation, NOT a physical delete: soft-delete
    # (is_deleted = true) that requires a body with a mandatory alasanPembatalan for the audit
    # trail. No auto-copy/duplicate logic — a replacement letter, if needed, is created from
    # scratch via a normal POST. updated_by comes from the token's `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:CancelNomorSuratRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:NomorSuratCancelled cancelled = check services:cancelNomorSurat(id, payload, subject);
            return successHttp(http:STATUS_OK, cancelled, "Surat berhasil dibatalkan");
        } on fail error err {
            return errorHttp(err, "Failed to cancel surat");
        }
    }
}

# Sales Unit — Proyek CRUD, plus the lightweight "Project Tujuan" dropdown the Daftar Surat form
# uses. Same JWKS-based access token guard/conventions as the other business services. `kodeProyek`
# is fully server-generated (see proyek_service/proyek_repository) — never accepted from the
# create/update bodies. `unitId`/`tahun` are immutable after create (embedded in kodeProyek);
# `status` is mutable on update but every change is logged to `log_status` and, on first
# transition into "DEAL_KONTRAK", auto-sets `tanggalDeal`.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/proyek on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("PROYEK", {"team-member": "TEAM_MEMBER"})];

    # GET /api/v1/business/proyek/dropdown — up to 100 active proyek (newest first), optional search.
    # Declared before `.`/`[int id]` for the same routing-precedence reason as
    # `/api/v1/master/units/tree`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get dropdown(string? search) returns http:Response {
        do {
            models:ProyekDropdownItem[] items = check services:getProyekDropdown(search);
            return successHttp(http:STATUS_OK, items, "Daftar proyek untuk dropdown");
        } on fail error err {
            return errorHttp(err, "Failed to get proyek dropdown");
        }
    }

    # GET /api/v1/business/proyek — paginated list, optional search + customer/industri/unit/
    # PIC Sales/status/tahun filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? customer_id, int? industri_id, int? unit_id,
            int? pic_sales_id, string? status, int? tahun, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:ProyekListResult result = check services:getProyek(
                    search, customer_id, industri_id, unit_id, pic_sales_id, status, tahun, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar proyek berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get proyek");
        }
    }

    # GET /api/v1/business/proyek/{id} — single proyek detail (joined display names + audit columns).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Proyek proyek = check services:getProyekById(id);
            return successHttp(http:STATUS_OK, proyek, "Detail proyek berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get proyek detail");
        }
    }

    # GET /api/v1/business/proyek/{id}/log-status — status-transition history (newest first).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]/log\-status() returns http:Response {
        do {
            models:ProyekLogStatus[] logStatus = check services:getProyekLogStatus(id);
            return successHttp(http:STATUS_OK, logStatus, "Riwayat status proyek berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get proyek log status");
        }
    }

    # POST /api/v1/business/proyek — create. kodeProyek is server-generated. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ProyekCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Proyek created = check services:createProyek(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Proyek berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create proyek");
        }
    }

    # PUT /api/v1/business/proyek/{id} — update mutable fields (kodeProyek/unitId/tahun immutable).
    # updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ProyekUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Proyek updated = check services:updateProyek(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Proyek berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update proyek");
        }
    }

    # DELETE /api/v1/business/proyek/{id} — soft delete (is_deleted = true).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteProyek(id, subject);
            return successHttp(http:STATUS_OK, (), "Proyek berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete proyek");
        }
    }

    // ----- Unit Share (pembagian nilai proyek antar unit) -----

    # GET /api/v1/business/proyek/{proyekId}/unit-share — all shares of a proyek (with unit names).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int proyekId]/unit\-share() returns http:Response {
        do {
            models:UnitShare[] items = check services:getUnitShare(proyekId);
            return successHttp(http:STATUS_OK, items, "Daftar unit share berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get unit share");
        }
    }

    # POST /api/v1/business/proyek/{proyekId}/unit-share — add a share. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post [int proyekId]/unit\-share(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UnitShareCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:UnitShare created = check services:createUnitShare(proyekId, payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Unit share berhasil ditambahkan");
        } on fail error err {
            return errorHttp(err, "Failed to create unit share");
        }
    }

    # PUT /api/v1/business/proyek/{proyekId}/unit-share/{id} — update a share. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int proyekId]/unit\-share/[int id](
            @http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UnitShareUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:UnitShare updated = check services:updateUnitShare(proyekId, id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Unit share berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update unit share");
        }
    }

    # DELETE /api/v1/business/proyek/{proyekId}/unit-share/{id} — soft delete a share.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int proyekId]/unit\-share/[int id](
            @http:Header {name: "Authorization"} string? authorization) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteUnitShare(proyekId, id, subject);
            return successHttp(http:STATUS_OK, (), "Unit share berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete unit share");
        }
    }

    // ----- Team Member (penugasan karyawan ke proyek per periode) -----

    # GET /api/v1/business/proyek/{proyekId}/team-member — all team members of a proyek (with names).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int proyekId]/team\-member() returns http:Response {
        do {
            models:TeamMember[] items = check services:getTeamMember(proyekId);
            return successHttp(http:STATUS_OK, items, "Daftar team member berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get team member");
        }
    }

    # POST /api/v1/business/proyek/{proyekId}/team-member — assign a member. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post [int proyekId]/team\-member(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TeamMemberCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:TeamMember created = check services:createTeamMember(proyekId, payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Team member berhasil ditambahkan");
        } on fail error err {
            return errorHttp(err, "Failed to create team member");
        }
    }

    # PUT /api/v1/business/proyek/{proyekId}/team-member/{id} — update a member. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int proyekId]/team\-member/[int id](
            @http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TeamMemberUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:TeamMember updated = check services:updateTeamMember(proyekId, id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Team member berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update team member");
        }
    }

    # DELETE /api/v1/business/proyek/{proyekId}/team-member/{id} — soft delete a member.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int proyekId]/team\-member/[int id](
            @http:Header {name: "Authorization"} string? authorization) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteTeamMember(proyekId, id, subject);
            return successHttp(http:STATUS_OK, (), "Team member berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete team member");
        }
    }

    // ----- Proyek Tags (many-to-many proyek <-> tags) -----

    # GET /api/v1/business/proyek/{proyekId}/tags — tags currently attached to a proyek.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int proyekId]/tags() returns http:Response {
        do {
            models:ProyekTag[] items = check services:getProyekTags(proyekId);
            return successHttp(http:STATUS_OK, items, "Daftar tag proyek berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get proyek tags");
        }
    }

    # PUT /api/v1/business/proyek/{proyekId}/tags — replace the proyek's entire tag set.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int proyekId]/tags(@http:Payload models:ProyekTagsUpdateRequest payload)
            returns http:Response {
        do {
            models:ProyekTag[] items = check services:replaceProyekTags(proyekId, payload);
            return successHttp(http:STATUS_OK, items, "Tag proyek berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to replace proyek tags");
        }
    }

    # POST /api/v1/business/proyek/{proyekId}/tags/{tagId} — attach a single tag (idempotent).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post [int proyekId]/tags/[int tagId]() returns http:Response {
        do {
            models:ProyekTag[] items = check services:attachProyekTag(proyekId, tagId);
            return successHttp(http:STATUS_OK, items, "Tag berhasil ditambahkan ke proyek");
        } on fail error err {
            return errorHttp(err, "Failed to attach proyek tag");
        }
    }

    # DELETE /api/v1/business/proyek/{proyekId}/tags/{tagId} — detach a single tag.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int proyekId]/tags/[int tagId]() returns http:Response {
        do {
            check services:detachProyekTag(proyekId, tagId);
            return successHttp(http:STATUS_OK, (), "Tag berhasil dilepas dari proyek");
        } on fail error err {
            return errorHttp(err, "Failed to detach proyek tag");
        }
    }
}

# ===== Sales Unit — Kontrak Payung service (`/api/v1/business/kontrak-payung`) =====
#
# Full CRUD for Kontrak Payung + its per-role price lines (`hargaRole`), plus a lightweight dropdown
# consumed by the Proyek form. Same JWKS-based access token guard/conventions as the other business
# services. Price lines are managed inline with the contract (replace-on-update); `noKontrakPayung`
# is unique; delete is refused while any active proyek/kontrak biasa still references the contract.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/kontrak\-payung on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("KONTRAK_PAYUNG")];

    # GET /api/v1/business/kontrak-payung/dropdown — up to 100 active kontrak payung (newest first),
    # optional customer_id + search filters. Declared before `.`/`[int id]` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get dropdown(int? customer_id, string? search) returns http:Response {
        do {
            models:KontrakPayungDropdownItem[] items = check services:getKontrakPayungDropdown(customer_id, search);
            return successHttp(http:STATUS_OK, items, "Daftar kontrak payung untuk dropdown");
        } on fail error err {
            return errorHttp(err, "Failed to get kontrak payung dropdown");
        }
    }

    # GET /api/v1/business/kontrak-payung — paginated list, optional search + customer_id filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? customer_id, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:KontrakPayungListResult result = check services:getKontrakPayung(
                    search, customer_id, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar kontrak payung berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get kontrak payung");
        }
    }

    # GET /api/v1/business/kontrak-payung/{id} — single contract detail (with price lines).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:KontrakPayung kontrak = check services:getKontrakPayungById(id);
            return successHttp(http:STATUS_OK, kontrak, "Detail kontrak payung berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get kontrak payung detail");
        }
    }

    # POST /api/v1/business/kontrak-payung — create (with optional price lines). created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KontrakPayungCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KontrakPayung created = check services:createKontrakPayung(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Kontrak payung berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create kontrak payung");
        }
    }

    # PUT /api/v1/business/kontrak-payung/{id} — update. Price lines replaced only when `hargaRole` is
    # present in the body. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KontrakPayungUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KontrakPayung updated = check services:updateKontrakPayung(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Kontrak payung berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update kontrak payung");
        }
    }

    # DELETE /api/v1/business/kontrak-payung/{id} — soft delete (refused while still referenced).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteKontrakPayung(id, subject);
            return successHttp(http:STATUS_OK, (), "Kontrak payung berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete kontrak payung");
        }
    }
}

# ===== Sales Unit — Kontrak Biasa service (`/api/v1/business/kontrak-biasa`) =====
#
# Full CRUD for Kontrak Biasa plus a lightweight dropdown consumed by the Proyek form. Same
# JWKS-based access token guard/conventions as the other business services. A kontrak biasa may be
# standalone or hang under a kontrak payung (same customer); `noKontrakBiasa` is unique; delete is
# refused while any active proyek still references the contract.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/kontrak\-biasa on apiListener {
    // Not RBAC-gated yet: there is no `KONTRAK_BIASA` row in the `modul` master (only KONTRAK_PAYUNG),
    // so no permission mapping exists. TODO(rbac): add a modul + wire a PermissionInterceptor once the
    // product decides where kontrak-biasa sits in the matrix.
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/business/kontrak-biasa/dropdown — up to 100 active kontrak biasa (newest first),
    # optional customer_id + search filters. Declared before `.`/`[int id]` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get dropdown(int? customer_id, string? search) returns http:Response {
        do {
            models:KontrakBiasaDropdownItem[] items = check services:getKontrakBiasaDropdown(customer_id, search);
            return successHttp(http:STATUS_OK, items, "Daftar kontrak biasa untuk dropdown");
        } on fail error err {
            return errorHttp(err, "Failed to get kontrak biasa dropdown");
        }
    }

    # GET /api/v1/business/kontrak-biasa — paginated list, optional search + customer_id/kontrak_payung_id.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? customer_id, int? kontrak_payung_id, int page = 1,
            int 'limit = 20) returns http:Response {
        do {
            models:KontrakBiasaListResult result = check services:getKontrakBiasa(
                    search, customer_id, kontrak_payung_id, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar kontrak biasa berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get kontrak biasa");
        }
    }

    # GET /api/v1/business/kontrak-biasa/{id} — single contract detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:KontrakBiasa kontrak = check services:getKontrakBiasaById(id);
            return successHttp(http:STATUS_OK, kontrak, "Detail kontrak biasa berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get kontrak biasa detail");
        }
    }

    # POST /api/v1/business/kontrak-biasa — create. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KontrakBiasaCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KontrakBiasa created = check services:createKontrakBiasa(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Kontrak biasa berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create kontrak biasa");
        }
    }

    # PUT /api/v1/business/kontrak-biasa/{id} — update. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KontrakBiasaUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KontrakBiasa updated = check services:updateKontrakBiasa(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Kontrak biasa berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update kontrak biasa");
        }
    }

    # DELETE /api/v1/business/kontrak-biasa/{id} — soft delete (refused while still referenced).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteKontrakBiasa(id, subject);
            return successHttp(http:STATUS_OK, (), "Kontrak biasa berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete kontrak biasa");
        }
    }
}

# ===== Sales Unit — Target Revenue Unit service (`/api/v1/business/target-revenue-unit`) =====
#
# CRUD for the per-unit-per-year revenue targets (split across four triwulan). Same JWKS-based access
# token guard/conventions as the other business services. Each (unit, tahun) pair is unique; delete is
# physical (the table has no soft-delete column).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/target\-revenue\-unit on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("TARGET_SALES_UNIT")];

    # GET /api/v1/business/target-revenue-unit — paginated list, optional search + unit_id/tahun filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? unit_id, int? tahun, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:TargetRevenueUnitListResult result = check services:getTargetRevenueUnit(
                    search, unit_id, tahun, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar target revenue unit berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get target revenue unit");
        }
    }

    # GET /api/v1/business/target-revenue-unit/{id} — single target row detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:TargetRevenueUnit row = check services:getTargetRevenueUnitById(id);
            return successHttp(http:STATUS_OK, row, "Detail target revenue unit berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get target revenue unit detail");
        }
    }

    # POST /api/v1/business/target-revenue-unit — create. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TargetRevenueUnitCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:TargetRevenueUnit created = check services:createTargetRevenueUnit(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Target revenue unit berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create target revenue unit");
        }
    }

    # PUT /api/v1/business/target-revenue-unit/{id} — update. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TargetRevenueUnitUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:TargetRevenueUnit updated = check services:updateTargetRevenueUnit(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Target revenue unit berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update target revenue unit");
        }
    }

    # DELETE /api/v1/business/target-revenue-unit/{id} — physical delete.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            check services:deleteTargetRevenueUnit(id);
            return successHttp(http:STATUS_OK, (), "Target revenue unit berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete target revenue unit");
        }
    }
}

# ===== Sales Unit — Revenue Unit reports service (`/api/v1/business/revenue-unit`) =====
#
# Read-only reporting combining stored targets (`target_revenue_unit`) with cash-basis actuals
# (`v_realisasi_revenue_tw`). Three GET endpoints: `.` full per-unit report, `/tw` per-triwulan
# report, `/chart` four-quarter chart data. Same JWKS-based access token guard as the other business
# services. `tahun` defaults to the current year when omitted.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/revenue\-unit on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("REVENUE_UNIT", {"tw": "REVENUE_UNIT_TW"})];

    # GET /api/v1/business/revenue-unit/chart — four-quarter target vs realisasi chart for a year,
    # optionally scoped to one unit. Declared before `.` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get chart(int? tahun, int? unit_id) returns http:Response {
        do {
            models:RevenueUnitChart data = check services:getRevenueUnitChart(tahun, unit_id);
            return successHttp(http:STATUS_OK, data, "Chart revenue unit berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get chart revenue unit");
        }
    }

    # GET /api/v1/business/revenue-unit/tw — per-triwulan target vs realisasi per unit. `triwulan`
    # (1..4) is required. Declared before `.` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get tw(int triwulan, int? tahun, int? unit_id) returns http:Response {
        do {
            models:RevenueUnitTwRow[] rows = check services:getRevenueUnitTw(tahun, triwulan, unit_id);
            return successHttp(http:STATUS_OK, rows, "Revenue unit per triwulan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get revenue unit per triwulan");
        }
    }

    # GET /api/v1/business/revenue-unit — full per-unit report (target vs realisasi, all triwulan +
    # total + pencapaian) for a year, optionally scoped to one unit.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(int? tahun, int? unit_id) returns http:Response {
        do {
            models:RevenueUnitRow[] rows = check services:getRevenueUnitReport(tahun, unit_id);
            return successHttp(http:STATUS_OK, rows, "Revenue unit berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get revenue unit");
        }
    }
}

# ===== Profil Saya service (`/api/v1/profil-saya`) =====
#
# Self-service view/update of the caller's own karyawan record, resolved via the `subject_id`
# linked to their WSO2 IS identity (the access token's `sub` claim — never a path/query id, so a
# caller can only ever see/edit their own profile). Only `email`/`noHp` are editable here;
# nik/nama/jabatan/unit/status stay HR-managed via `/api/v1/master/karyawan`.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "PUT", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/profil\-saya on apiListener {
    // Not RBAC-gated: self-service on the caller's OWN karyawan record (resolved from their token's
    // subject_id), so it must stay reachable by every authenticated user regardless of role.
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/profil-saya — the caller's own karyawan profile.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(@http:Header {name: "Authorization"} string? authorization) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KaryawanDetail profil = check services:getMyProfile(subject);
            return successHttp(http:STATUS_OK, profil, "Profil berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get profil saya");
        }
    }

    # PUT /api/v1/profil-saya — update the caller's own contact info (email, noHp only).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ProfilSayaUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KaryawanDetail updated = check services:updateMyProfile(subject, payload);
            return successHttp(http:STATUS_OK, updated, "Profil berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update profil saya");
        }
    }
}

# ===== Akun Saya service (`/api/v1/akun-saya`) =====
#
# Self-service update of the caller's OWN identity in WSO2 Identity Server — password, email, first
# name, last name, phone. Distinct from Profil Saya above: Profil Saya edits the local karyawan HR
# contact record (nik/nama/jabatan stay HR-managed, only email/noHp are self-editable there);
# Akun Saya edits the actual WSO2 IS login identity via SCIM2 (services:updateMyAccount ->
# repositories:scimAdminPatch). The target subject_id always comes from the caller's own validated
# access token (`sub` claim via utils:subjectFromAccessToken) — never a path/query parameter — so a
# caller can only ever reach their own WSO2 IS identity here.
#
# `swaportal_role_id` is deliberately NOT editable from this endpoint: letting a user set their own
# portal role would be a privilege-escalation hole. Role changes stay admin-only, via the pre-existing
# PUT /api/v1/manajemen-user/{subjectId}/role or the new PUT /api/v1/manajemen-user/{subjectId}/akun.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "PUT", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/akun\-saya on apiListener {
    // Not RBAC-gated: self-service on the caller's OWN WSO2 IS identity, so it must stay reachable
    // by every authenticated user regardless of role — same rationale as Profil Saya/Menu Saya.
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/akun-saya — the caller's own WSO2 IS identity snapshot, to prefill the edit form.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(@http:Header {name: "Authorization"} string? authorization) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:AkunProfile profile = check services:getMyAccount(subject);
            return successHttp(http:STATUS_OK, profile, "Akun berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get akun saya");
        }
    }

    # PUT /api/v1/akun-saya — update the caller's own WSO2 IS identity (password/email/first name/
    # last name/phone). Every field optional (only fields sent are changed); role is not editable
    # here (see service doc above).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:AkunSayaUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:AkunProfile updated = check services:updateMyAccount(subject, payload);
            return successHttp(http:STATUS_OK, updated, "Akun berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update akun saya");
        }
    }

    # PUT /api/v1/akun-saya/password — change the caller's own WSO2 IS password (separate from the
    # data-update form above).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put password(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PasswordUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:updateMyPassword(subject, payload);
            return successHttp(http:STATUS_OK, (), "Password berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update password");
        }
    }
}

# ===== Menu Saya service (`/api/v1/menu-saya`) =====
#
# The sidebar navigation for the logged-in user: the menu tree filtered to exactly the menus their
# role has been assigned (and that are still AKTIF). The role is resolved from the caller's own
# `swaportal_role_id` claim inside `services:getMyMenu`, never a path/query id — so a user only ever
# sees the menus their own role grants. Not RBAC-gated (every authenticated app-group user needs
# their menu), but still behind the JWKS + app-group scope guard like every protected service.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/menu\-saya on apiListener {
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/menu-saya — the caller's role-filtered navigation menu tree.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(@http:Header {name: "Authorization"} string? authorization) returns http:Response {
        do {
            string token = check utils:bearerToken(authorization);
            models:MenuTreeNode[] menu = check services:getMyMenu(token);
            return successHttp(http:STATUS_OK, menu, "Menu berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get menu saya");
        }
    }
}

# ===== Notifikasi service (`/api/v1/notifikasi`) =====
#
# Self-service notification inbox, scoped to the caller's own karyawan id (resolved from the access
# token, same as Profil Saya) — a notification belonging to another user is never listed, counted,
# or markable. Read/acknowledge only: notifications are written by other business flows (a future
# concern), not created via this API.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "PUT", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/notifikasi on apiListener {
    // Not RBAC-gated: self-service inbox scoped to the caller's own karyawan id, so every
    // authenticated user reaches only their own notifications regardless of role.
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/notifikasi/unread-count — the caller's unread notification count (for a badge).
    # Declared before `.` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get unread\-count(@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:NotificationUnreadCount count = check services:getNotifikasiUnreadCount(subject);
            return successHttp(http:STATUS_OK, count, "Jumlah notifikasi belum dibaca berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get notifikasi unread count");
        }
    }

    # GET /api/v1/notifikasi — paginated list of the caller's own notifications, optional
    # kategori/is_read filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(@http:Header {name: "Authorization"} string? authorization, string? kategori,
            boolean? is_read, int page = 1, int 'limit = 20) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:NotificationListResult result = check services:getNotifikasi(
                    subject, kategori, is_read, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar notifikasi berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get notifikasi");
        }
    }

    # PUT /api/v1/notifikasi/read-all — mark all of the caller's unread notifications as read.
    # Declared before `[int id]/read` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put read\-all(@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:markAllNotifikasiRead(subject);
            return successHttp(http:STATUS_OK, (), "Semua notifikasi ditandai sudah dibaca");
        } on fail error err {
            return errorHttp(err, "Failed to mark all notifikasi read");
        }
    }

    # PUT /api/v1/notifikasi/{id}/read — mark one of the caller's own notifications as read.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id]/read(@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:markNotifikasiRead(subject, id);
            return successHttp(http:STATUS_OK, (), "Notifikasi ditandai sudah dibaca");
        } on fail error err {
            return errorHttp(err, "Failed to mark notifikasi read");
        }
    }
}

# ===== Audit Log service (`/api/v1/audit-log`) — read-only =====
#
# Read-only reporting over the append-only `audit_log` table (written internally by other services,
# e.g. `nomor_surat_service` on cancel). No create/update/delete endpoint — the table is append-only
# by design.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/audit\-log on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("AUDIT_TRAIL")];

    # GET /api/v1/audit-log — paginated list, optional table_name/aksi/aktor/record_id/date_from/date_to filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? table_name, string? aksi, string? aktor, string? record_id,
            string? date_from, string? date_to, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:AuditLogListResult result = check services:getAuditLog(
                    table_name, aksi, aktor, record_id, date_from, date_to, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar audit log berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get audit log");
        }
    }

    # GET /api/v1/audit-log/{id} — single audit log entry detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:AuditLogEntry entry = check services:getAuditLogById(id);
            return successHttp(http:STATUS_OK, entry, "Detail audit log berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get audit log detail");
        }
    }
}

# ===== Konfigurasi Sistem service (`/api/v1/konfigurasi-sistem`) =====
#
# CRUD-lite over the fixed, seeded `sys_config` key-value registry: list/get every setting, and
# update the `value` of an existing key. There is no create/delete — the set of keys is fixed at
# schema build time and referenced by name throughout the codebase (e.g. `prefix_kode_proyek`).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "PUT", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/konfigurasi\-sistem on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("KONFIGURASI_SISTEM")];

    # GET /api/v1/konfigurasi-sistem — every setting, optional search over key/deskripsi, no pagination.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search) returns http:Response {
        do {
            models:SysConfig[] configs = check services:getSysConfig(search);
            return successHttp(http:STATUS_OK, configs, "Daftar konfigurasi sistem berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get konfigurasi sistem");
        }
    }

    # GET /api/v1/konfigurasi-sistem/{key} — single setting detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [string konfigKey]() returns http:Response {
        do {
            models:SysConfig config = check services:getSysConfigByKey(konfigKey);
            return successHttp(http:STATUS_OK, config, "Detail konfigurasi sistem berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get konfigurasi sistem detail");
        }
    }

    # PUT /api/v1/konfigurasi-sistem/{key} — update a setting's value. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [string konfigKey](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:SysConfigUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:SysConfig updated = check services:updateSysConfigValue(konfigKey, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Konfigurasi sistem berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update konfigurasi sistem");
        }
    }
}

# ===== Manajemen User service (`/api/v1/manajemen-user`) =====
#
# Reads list `user_cache` (the local mirror of WSO2 IS users), LEFT JOINed to `karyawan` so the admin
# screen shows which karyawan (if any) each WSO2 identity is linked to. Writes (create user, update
# profile, set role, enable/disable) go through WSO2's SCIM2 API with an app-level credential (schema
# implementation note #2), not this database — see services:createUser/updateUser/setUserRole/
# setUserStatus and repositories/scim2_repository.bal. Each successful SCIM2 write is write-through
# mirrored into `user_cache` so the read side reflects it immediately. NOTE: the SCIM2 write path is
# implemented to spec but could not be verified against a live WSO2 IS in this environment.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/manajemen\-user on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("USER")];

    # GET /api/v1/manajemen-user — paginated list, optional search + status filter, LEFT JOINed to karyawan.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, string? status, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:UserCacheListResult result = check services:getUserCache(search, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar user berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get manajemen user");
        }
    }

    # GET /api/v1/manajemen-user/{subjectId} — single cached WSO2 IS user (+ linked karyawan, if any).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [string subjectId]() returns http:Response {
        do {
            models:UserCacheItem item = check services:getUserCacheBySubjectId(subjectId);
            return successHttp(http:STATUS_OK, item, "Detail user berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get manajemen user detail");
        }
    }

    # POST /api/v1/manajemen-user — provision a new WSO2 IS user via SCIM2 (+ write-through cache).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UserCreateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            models:UserCacheItem created = check services:createUser(payload);
            return successHttp(http:STATUS_CREATED, created, "User berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create user");
        }
    }

    # PUT /api/v1/manajemen-user/{subjectId} — update a user's profile (nama/email) via SCIM2.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [string subjectId](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UserUpdateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            models:UserCacheItem updated = check services:updateUser(subjectId, payload);
            return successHttp(http:STATUS_OK, updated, "User berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update user");
        }
    }

    # PUT /api/v1/manajemen-user/{subjectId}/role — set/clear the portal role (swaportal_role_id).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [string subjectId]/role(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UserRoleUpdateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            models:UserCacheItem updated = check services:setUserRole(subjectId, payload);
            return successHttp(http:STATUS_OK, updated, "Role user berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to set user role");
        }
    }

    # PUT /api/v1/manajemen-user/{subjectId}/status — enable/disable the account (SCIM `active`).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [string subjectId]/status(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UserStatusUpdateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            models:UserCacheItem updated = check services:setUserStatus(subjectId, payload);
            return successHttp(http:STATUS_OK, updated, "Status user berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to set user status");
        }
    }

    # GET /api/v1/manajemen-user/{subjectId}/akun — a user's full WSO2 IS identity snapshot, to
    # prefill the Super Admin edit form before calling PUT .../akun.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [string subjectId]/akun() returns http:Response {
        do {
            models:AkunProfile profile = check services:getUserAccount(subjectId);
            return successHttp(http:STATUS_OK, profile, "Akun user berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get user akun");
        }
    }

    # PUT /api/v1/manajemen-user/{subjectId}/akun — Super Admin updates ANOTHER user's full WSO2 IS
    # identity (password reset, email, first/last name, phone, portal role) in one call, running as
    # the Super Admin IS account (config:scimAdminUsername/scimAdminPassword) rather than the
    # app-level credential the endpoints above use. Every field optional (only fields sent change).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [string subjectId]/akun(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:UserAccountUpdateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            models:AkunProfile updated = check services:updateUserAccount(subjectId, payload);
            return successHttp(http:STATUS_OK, updated, "Akun user berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update user akun");
        }
    }

    # PUT /api/v1/manajemen-user/{subjectId}/password — Super Admin resets ANOTHER user's WSO2 IS
    # password (separate from the data-update form at PUT .../akun).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [string subjectId]/password(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PasswordUpdateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            check services:updateUserPassword(subjectId, payload);
            return successHttp(http:STATUS_OK, (), "Password user berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update user password");
        }
    }
}

# ===== Finansial — Tagihan service (`/api/v1/finance/tagihan`) =====
#
# CRUD for tagihan (invoices) + their status history, and the Pencairan sub-resource
# (`/{id}/pencairan`) — staged cash-in realizations of a tagihan. Same JWKS-based access token guard
# as the other business services. `noTagihan` is unique; status changes are logged to
# `status_tagihan`; the sum of a tagihan's non-cancelled pencairan may not exceed its `nilaiTagihan`.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/finance/tagihan on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("TAGIHAN", {"pencairan": "PENCAIRAN"})];

    # GET /api/v1/finance/tagihan — paginated list, optional search + proyek_id/status_aktif filters.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? proyek_id, string? status_aktif, int page = 1,
            int 'limit = 20) returns http:Response {
        do {
            models:TagihanListResult result = check services:getTagihan(search, proyek_id, status_aktif, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar tagihan berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get tagihan");
        }
    }

    # GET /api/v1/finance/tagihan/{id} — single tagihan detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Tagihan tagihan = check services:getTagihanById(id);
            return successHttp(http:STATUS_OK, tagihan, "Detail tagihan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get tagihan detail");
        }
    }

    # GET /api/v1/finance/tagihan/{id}/status-history — status-transition history (newest first).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]/status\-history() returns http:Response {
        do {
            models:TagihanStatusHistory[] history = check services:getTagihanStatusHistory(id);
            return successHttp(http:STATUS_OK, history, "Riwayat status tagihan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get tagihan status history");
        }
    }

    # POST /api/v1/finance/tagihan — create. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TagihanCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Tagihan created = check services:createTagihan(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Tagihan berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create tagihan");
        }
    }

    # PUT /api/v1/finance/tagihan/{id} — update. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TagihanUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Tagihan updated = check services:updateTagihan(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Tagihan berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update tagihan");
        }
    }

    # DELETE /api/v1/finance/tagihan/{id} — soft delete.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteTagihan(id, subject);
            return successHttp(http:STATUS_OK, (), "Tagihan berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete tagihan");
        }
    }

    // ----- Pencairan (staged cash-in realization of a tagihan) -----

    # GET /api/v1/finance/tagihan/{tagihanId}/pencairan — all pencairan of a tagihan.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int tagihanId]/pencairan() returns http:Response {
        do {
            models:PencairanTagihan[] items = check services:getPencairan(tagihanId);
            return successHttp(http:STATUS_OK, items, "Daftar pencairan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get pencairan");
        }
    }

    # POST /api/v1/finance/tagihan/{tagihanId}/pencairan — add a pencairan. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post [int tagihanId]/pencairan(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PencairanCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:PencairanTagihan created = check services:createPencairan(tagihanId, payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Pencairan berhasil ditambahkan");
        } on fail error err {
            return errorHttp(err, "Failed to create pencairan");
        }
    }

    # PUT /api/v1/finance/tagihan/{tagihanId}/pencairan/{id} — update a pencairan.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int tagihanId]/pencairan/[int id](
            @http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PencairanUpdateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            models:PencairanTagihan updated = check services:updatePencairan(tagihanId, id, payload);
            return successHttp(http:STATUS_OK, updated, "Pencairan berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update pencairan");
        }
    }

    # DELETE /api/v1/finance/tagihan/{tagihanId}/pencairan/{id} — soft delete a pencairan.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int tagihanId]/pencairan/[int id](
            @http:Header {name: "Authorization"} string? authorization) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            check services:deletePencairan(tagihanId, id);
            return successHttp(http:STATUS_OK, (), "Pencairan berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete pencairan");
        }
    }
}

# ===== Finansial — Pembayaran service (`/api/v1/finance/pembayaran`) =====
#
# CRUD for pembayaran (project-tied cash-out) plus the approve/reject workflow. Same JWKS-based
# access token guard as the other business services. See `pembayaran_service` for the important note
# that approval AUTHORIZATION (who may approve) is deferred — only the state machine is enforced here.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/finance/pembayaran on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("PEMBAYARAN")];

    # GET /api/v1/finance/pembayaran — paginated list, optional search + proyek_id/kategori_id/status.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? proyek_id, int? kategori_id, string? status, int page = 1,
            int 'limit = 20) returns http:Response {
        do {
            models:PembayaranListResult result = check services:getPembayaran(
                    search, proyek_id, kategori_id, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar pembayaran berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get pembayaran");
        }
    }

    # GET /api/v1/finance/pembayaran/{id} — single pembayaran detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:Pembayaran pembayaran = check services:getPembayaranById(id);
            return successHttp(http:STATUS_OK, pembayaran, "Detail pembayaran berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get pembayaran detail");
        }
    }

    # POST /api/v1/finance/pembayaran — create (status PENGAJUAN). created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PembayaranCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Pembayaran created = check services:createPembayaran(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Pembayaran berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create pembayaran");
        }
    }

    # PUT /api/v1/finance/pembayaran/{id} — update (only PENGAJUAN/REJECTED; resets to PENGAJUAN).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PembayaranUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Pembayaran updated = check services:updatePembayaran(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Pembayaran berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update pembayaran");
        }
    }

    # PUT /api/v1/finance/pembayaran/{id}/approve — approve a PENGAJUAN pembayaran. approved_by from token.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id]/approve(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ApproveRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Pembayaran approved = check services:approvePembayaran(id, payload, subject);
            return successHttp(http:STATUS_OK, approved, "Pembayaran berhasil di-approve");
        } on fail error err {
            return errorHttp(err, "Failed to approve pembayaran");
        }
    }

    # PUT /api/v1/finance/pembayaran/{id}/reject — reject a PENGAJUAN pembayaran. approved_by from token.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id]/reject(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:RejectRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:Pembayaran rejected = check services:rejectPembayaran(id, payload, subject);
            return successHttp(http:STATUS_OK, rejected, "Pembayaran berhasil di-reject");
        } on fail error err {
            return errorHttp(err, "Failed to reject pembayaran");
        }
    }

    # DELETE /api/v1/finance/pembayaran/{id} — soft delete.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deletePembayaran(id, subject);
            return successHttp(http:STATUS_OK, (), "Pembayaran berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete pembayaran");
        }
    }
}

# ===== Finansial — Pengeluaran Perusahaan service (`/api/v1/finance/pengeluaran-perusahaan`) =====
#
# CRUD for pengeluaran perusahaan (unit-tied internal cash-out) plus the approve/reject workflow —
# the twin of Pembayaran, keyed on a unit instead of a proyek. Same JWKS-based access token guard.
# The same approval-authorization deferral (see `pembayaran_service`) applies.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/finance/pengeluaran\-perusahaan on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("PENGELUARAN_PERUSAHAAN")];

    # GET /api/v1/finance/pengeluaran-perusahaan — paginated list, optional search + unit_id/kategori_id/status.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? unit_id, int? kategori_id, string? status, int page = 1,
            int 'limit = 20) returns http:Response {
        do {
            models:PengeluaranListResult result = check services:getPengeluaran(
                    search, unit_id, kategori_id, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar pengeluaran berhasil diambil", result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get pengeluaran");
        }
    }

    # GET /api/v1/finance/pengeluaran-perusahaan/{id} — single pengeluaran detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:PengeluaranPerusahaan pengeluaran = check services:getPengeluaranById(id);
            return successHttp(http:STATUS_OK, pengeluaran, "Detail pengeluaran berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get pengeluaran detail");
        }
    }

    # POST /api/v1/finance/pengeluaran-perusahaan — create (status PENGAJUAN). created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PengeluaranCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:PengeluaranPerusahaan created = check services:createPengeluaran(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Pengeluaran berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create pengeluaran");
        }
    }

    # PUT /api/v1/finance/pengeluaran-perusahaan/{id} — update (only PENGAJUAN/REJECTED; resets to PENGAJUAN).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:PengeluaranUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:PengeluaranPerusahaan updated = check services:updatePengeluaran(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Pengeluaran berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update pengeluaran");
        }
    }

    # PUT /api/v1/finance/pengeluaran-perusahaan/{id}/approve — approve a PENGAJUAN pengeluaran.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id]/approve(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ApproveRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:PengeluaranPerusahaan approved = check services:approvePengeluaran(id, payload, subject);
            return successHttp(http:STATUS_OK, approved, "Pengeluaran berhasil di-approve");
        } on fail error err {
            return errorHttp(err, "Failed to approve pengeluaran");
        }
    }

    # PUT /api/v1/finance/pengeluaran-perusahaan/{id}/reject — reject a PENGAJUAN pengeluaran.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id]/reject(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:RejectRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:PengeluaranPerusahaan rejected = check services:rejectPengeluaran(id, payload, subject);
            return successHttp(http:STATUS_OK, rejected, "Pengeluaran berhasil di-reject");
        } on fail error err {
            return errorHttp(err, "Failed to reject pengeluaran");
        }
    }

    # DELETE /api/v1/finance/pengeluaran-perusahaan/{id} — soft delete.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deletePengeluaran(id, subject);
            return successHttp(http:STATUS_OK, (), "Pengeluaran berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete pengeluaran");
        }
    }
}

# ===== Finansial — Saldo Awal Kas service (`/api/v1/finance/saldo-awal-kas`) =====
#
# Append-only saldo_awal_kas (list/detail/create — no update/delete) plus a read of the current cash
# position (`/posisi-kas`, from the `v_posisi_kas` view). Same JWKS-based access token guard.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/finance/saldo\-awal\-kas on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("SALDO_AWAL_KAS")];

    # GET /api/v1/finance/saldo-awal-kas/posisi-kas — current cash position (from v_posisi_kas).
    # Declared before `.`/`[int id]` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get posisi\-kas() returns http:Response {
        do {
            models:PosisiKas posisi = check services:getPosisiKas();
            return successHttp(http:STATUS_OK, posisi, "Posisi kas berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get posisi kas");
        }
    }

    # GET /api/v1/finance/saldo-awal-kas — paginated list (newest first).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:SaldoAwalKasListResult result = check services:getSaldoAwalKas(page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar saldo awal kas berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get saldo awal kas");
        }
    }

    # GET /api/v1/finance/saldo-awal-kas/{id} — single saldo awal kas detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:SaldoAwalKas row = check services:getSaldoAwalKasById(id);
            return successHttp(http:STATUS_OK, row, "Detail saldo awal kas berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get saldo awal kas detail");
        }
    }

    # POST /api/v1/finance/saldo-awal-kas — create (append-only). created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:SaldoAwalKasCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:SaldoAwalKas created = check services:createSaldoAwalKas(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Saldo awal kas berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create saldo awal kas");
        }
    }
}

# ===== Master Data — Kategori Finansial Keluar service (`/api/v1/master/kategori-finansial-keluar`) =====
#
# CRUD for the category master shared by Pembayaran and Pengeluaran Perusahaan. Not RBAC-gated: there
# is no dedicated `modul` row for it (like Tags/Jabatan), so it stays behind JWKS + denylist only.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/kategori\-finansial\-keluar on apiListener {
    // Not RBAC-gated: shared finance category master with no dedicated `modul` row. See README.
    public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];

    # GET /api/v1/master/kategori-finansial-keluar — paginated list, optional search + status filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, string? status, int page = 1, int 'limit = 20) returns http:Response {
        do {
            models:KategoriFinansialKeluarListResult result =
                check services:getKategoriFinansialKeluar(search, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar kategori finansial keluar berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get kategori finansial keluar");
        }
    }

    # GET /api/v1/master/kategori-finansial-keluar/{id} — single kategori detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:KategoriFinansialKeluar row = check services:getKategoriFinansialKeluarById(id);
            return successHttp(http:STATUS_OK, row, "Detail kategori finansial keluar berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get kategori finansial keluar detail");
        }
    }

    # POST /api/v1/master/kategori-finansial-keluar — create. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KategoriFinansialKeluarCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:KategoriFinansialKeluar created = check services:createKategoriFinansialKeluar(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Kategori finansial keluar berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create kategori finansial keluar");
        }
    }

    # PUT /api/v1/master/kategori-finansial-keluar/{id} — update (this table has no update-audit columns).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:KategoriFinansialKeluarUpdateRequest payload) returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            models:KategoriFinansialKeluar updated = check services:updateKategoriFinansialKeluar(id, payload);
            return successHttp(http:STATUS_OK, updated, "Kategori finansial keluar berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update kategori finansial keluar");
        }
    }

    # DELETE /api/v1/master/kategori-finansial-keluar/{id} — physical delete (guarded by references).
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            check services:deleteKategoriFinansialKeluar(id);
            return successHttp(http:STATUS_OK, (), "Kategori finansial keluar berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete kategori finansial keluar");
        }
    }
}

# ===== Sales Unit — Target Sales Unit service (`/api/v1/business/target-sales-unit`) =====
#
# CRUD for a unit's per-quarter sales (deal) target per year — the twin of target-revenue-unit. Each
# (unit, tahun) pair is unique; deletes are physical (no soft-delete column).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/target\-sales\-unit on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("TARGET_SALES_UNIT")];

    # GET /api/v1/business/target-sales-unit — paginated list, optional search + unit_id/tahun filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? unit_id, int? tahun, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:TargetSalesUnitListResult result = check services:getTargetSalesUnit(
                    search, unit_id, tahun, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar target sales unit berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get target sales unit");
        }
    }

    # GET /api/v1/business/target-sales-unit/{id} — single target row detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:TargetSalesUnit row = check services:getTargetSalesUnitById(id);
            return successHttp(http:STATUS_OK, row, "Detail target sales unit berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get target sales unit detail");
        }
    }

    # POST /api/v1/business/target-sales-unit — create. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TargetSalesUnitCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:TargetSalesUnit created = check services:createTargetSalesUnit(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Target sales unit berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create target sales unit");
        }
    }

    # PUT /api/v1/business/target-sales-unit/{id} — update. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:TargetSalesUnitUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:TargetSalesUnit updated = check services:updateTargetSalesUnit(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Target sales unit berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update target sales unit");
        }
    }

    # DELETE /api/v1/business/target-sales-unit/{id} — physical delete.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            _ = check utils:subjectFromAccessToken(authorization);
            check services:deleteTargetSalesUnit(id);
            return successHttp(http:STATUS_OK, (), "Target sales unit berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete target sales unit");
        }
    }
}

# ===== Sales Unit — Sales Matrix / Pencapaian Sales Unit service (`/api/v1/business/sales-matrix`) =====
#
# Read-only reporting combining stored sales targets (`target_sales_unit`) with deal-basis actuals
# (`v_realisasi_sales_tw`). Same shape as the Revenue Unit report: `.` full per-unit report, `/tw`
# per-triwulan, `/chart` four-quarter chart. Gated under the TARGET_SALES_UNIT modul (read).
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/sales\-matrix on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("TARGET_SALES_UNIT")];

    # GET /api/v1/business/sales-matrix/chart — four-quarter target vs realisasi chart for a year,
    # optionally scoped to one unit. Declared before `.` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get chart(int? tahun, int? unit_id) returns http:Response {
        do {
            models:SalesUnitChart data = check services:getSalesMatrixChart(tahun, unit_id);
            return successHttp(http:STATUS_OK, data, "Chart sales matrix berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get chart sales matrix");
        }
    }

    # GET /api/v1/business/sales-matrix/tw — per-triwulan target vs realisasi per unit. `triwulan`
    # (1..4) is required. Declared before `.` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get tw(int triwulan, int? tahun, int? unit_id) returns http:Response {
        do {
            models:SalesUnitTwRow[] rows = check services:getSalesMatrixTw(tahun, triwulan, unit_id);
            return successHttp(http:STATUS_OK, rows, "Sales matrix per triwulan berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get sales matrix per triwulan");
        }
    }

    # GET /api/v1/business/sales-matrix — full per-unit report (target vs realisasi, all triwulan +
    # total + pencapaian) for a year, optionally scoped to one unit.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(int? tahun, int? unit_id) returns http:Response {
        do {
            models:SalesUnitRow[] rows = check services:getSalesMatrixReport(tahun, unit_id);
            return successHttp(http:STATUS_OK, rows, "Sales matrix berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get sales matrix");
        }
    }
}

# ===== Resource Unit service (`/api/v1/master/resource-unit`) =====
#
# CRUD for resource_unit (headcount/capacity per unit; one row per unit). Gated under the
# RESOURCE_UNIT modul.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/master/resource\-unit on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("RESOURCE_UNIT")];

    # GET /api/v1/master/resource-unit — paginated list, optional search + unit_id/status filter.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(string? search, int? unit_id, string? status, int page = 1, int 'limit = 20)
            returns http:Response {
        do {
            models:ResourceUnitListResult result = check services:getResourceUnit(
                    search, unit_id, status, page, 'limit);
            return successHttp(http:STATUS_OK, result.items, "Daftar resource unit berhasil diambil",
                    result.pagination);
        } on fail error err {
            return errorHttp(err, "Failed to get resource unit");
        }
    }

    # GET /api/v1/master/resource-unit/{id} — single resource row detail.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get [int id]() returns http:Response {
        do {
            models:ResourceUnit row = check services:getResourceUnitById(id);
            return successHttp(http:STATUS_OK, row, "Detail resource unit berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get resource unit detail");
        }
    }

    # POST /api/v1/master/resource-unit — create. created_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function post .(@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ResourceUnitCreateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:ResourceUnit created = check services:createResourceUnit(payload, subject);
            return successHttp(http:STATUS_CREATED, created, "Resource unit berhasil dibuat");
        } on fail error err {
            return errorHttp(err, "Failed to create resource unit");
        }
    }

    # PUT /api/v1/master/resource-unit/{id} — update. updated_by from token `sub`.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function put [int id](@http:Header {name: "Authorization"} string? authorization,
            @http:Payload models:ResourceUnitUpdateRequest payload) returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            models:ResourceUnit updated = check services:updateResourceUnit(id, payload, subject);
            return successHttp(http:STATUS_OK, updated, "Resource unit berhasil diperbarui");
        } on fail error err {
            return errorHttp(err, "Failed to update resource unit");
        }
    }

    # DELETE /api/v1/master/resource-unit/{id} — soft delete.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function delete [int id](@http:Header {name: "Authorization"} string? authorization)
            returns http:Response {
        do {
            string subject = check utils:subjectFromAccessToken(authorization);
            check services:deleteResourceUnit(id, subject);
            return successHttp(http:STATUS_OK, (), "Resource unit berhasil dihapus");
        } on fail error err {
            return errorHttp(err, "Failed to delete resource unit");
        }
    }
}

# ===== Cashflow service (`/api/v1/business/cashflow`) =====
#
# Read-only, company-wide monthly cash-flow report + chart for a year (inflow from pencairan vs
# outflow from approved/realized pembayaran + pengeluaran), plus the current cash position from
# `v_posisi_kas`. Gated under the CASHFLOW modul (read). `tahun` defaults to the current year.
@http:ServiceConfig {
    cors: {
        allowOrigins: config:corsAllowedOrigins,
        allowMethods: ["GET", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: true,
        maxAge: 3600
    },
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {
                        url: config:jwksUrl
                    }
                }
            }
        }
    ]
}
service /api/v1/business/cashflow on apiListener {
    public function createInterceptors() returns http:Interceptor[] =>
        [tokenDenylistInterceptor, new PermissionInterceptor("CASHFLOW")];

    # GET /api/v1/business/cashflow/chart — twelve-month inflow-vs-outflow chart for a year.
    # Declared before `.` for routing precedence.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get chart(int? tahun) returns http:Response {
        do {
            models:CashflowChartPoint[] points = check services:getCashflowChart(tahun);
            return successHttp(http:STATUS_OK, points, "Chart cashflow berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get chart cashflow");
        }
    }

    # GET /api/v1/business/cashflow — twelve monthly inflow/outflow/net rows + totals + posisi kas.
    # + return - the HTTP response, JSON-encoded in the standard ApiResponse envelope
    resource function get .(int? tahun) returns http:Response {
        do {
            models:CashflowReport report = check services:getCashflowReport(tahun);
            return successHttp(http:STATUS_OK, report, "Cashflow berhasil diambil");
        } on fail error err {
            return errorHttp(err, "Failed to get cashflow");
        }
    }
}

# Builds a success response wrapping `data` in the standard envelope with the given status.
#
# + statusCode - the HTTP status code to respond with
# + data - the response payload
# + message - human-readable success message
# + pagination - optional pagination metadata, included in `meta.pagination` when present
# + return - the JSON-encoded `http:Response`
function successHttp(int statusCode, anydata data, string message, models:Pagination? pagination = ())
        returns http:Response {
    http:Response res = new;
    res.statusCode = statusCode;
    res.setJsonPayload(utils:successResponse(data, message, pagination).toJson());
    return res;
}

# Maps a caught error to an HTTP response. `models:AppError` carries its own status code and
# machine-readable code; anything else is logged and returned as a generic 500.
#
# + err - the caught error
# + logContext - message logged alongside unexpected (non-AppError) failures
# + return - the JSON-encoded `http:Response`
function errorHttp(error err, string logContext) returns http:Response {
    http:Response res = new;
    if err is models:AppError {
        var detail = err.detail();
        res.statusCode = detail.statusCode;
        res.setJsonPayload(utils:errorResponse(detail.code, err.message()).toJson());
        return res;
    }

    log:printError(logContext, err);
    res.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
    res.setJsonPayload(utils:errorResponse(
            "INTERNAL_ERROR",
            "Terjadi kesalahan pada server, silakan coba lagi nanti").toJson());
    return res;
}

# Builds a 200 response wrapping `data` in the standard success envelope.
#
# + data - the response payload
# + message - human-readable success message
# + return - the JSON-encoded `http:Response`
function okResponse(anydata data, string message) returns http:Response {
    http:Response res = new;
    res.statusCode = http:STATUS_OK;
    res.setJsonPayload(utils:successResponse(data, message).toJson());
    return res;
}

# Maps an AppError to an HTTP response using its statusCode. Server-side (5xx) errors are
# logged and returned with a generic message; client errors surface their own message.
#
# + err - the AppError to map
# + return - the JSON-encoded `http:Response`
function errorToResponse(models:AppError err) returns http:Response {
    int statusCode = err.detail().statusCode;
    string message = err.message();
    if statusCode >= 500 {
        log:printError("Request failed", err);
        message = "Terjadi kesalahan pada server, silakan coba lagi nanti";
    }

    http:Response res = new;
    res.statusCode = statusCode;
    res.setJsonPayload(utils:errorResponse(err.detail().code, message).toJson());
    return res;
}
