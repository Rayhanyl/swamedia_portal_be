import ballerina/jwt;
import rayha/swamedia_portal_be.config;
import rayha/swamedia_portal_be.models;

# Resolves the caller's IP from the standard reverse-proxy headers. There is no implicit
# request-scoped context in this Ballerina distribution (2201.13.4 has no `runtime:
# getInvocationContext`, and `http:RequestContext` is only reachable from interceptors/resource
# functions, not from arbitrary nested service calls) — so unlike `subject`, the IP genuinely has
# to be read per-request in main.bal and threaded through as a parameter down to
# `audit_log_service:logAudit`, the same way `subject` already is.
#
# + xForwardedFor - the `X-Forwarded-For` header value, if present (`"client, proxy1, proxy2"` —
#   the first hop is the original client)
# + xRealIp - the `X-Real-IP` header value, if present (checked when `X-Forwarded-For` is absent)
# + return - the resolved client IP, or () if neither header was present (e.g. unproxied local dev)
public function resolveClientIp(string? xForwardedFor, string? xRealIp) returns string? {
    if xForwardedFor is string {
        int? commaIdx = xForwardedFor.indexOf(",");
        string first = commaIdx is int ? xForwardedFor.substring(0, commaIdx) : xForwardedFor;
        string trimmed = first.trim();
        if trimmed.length() > 0 {
            return trimmed;
        }
    }
    if xRealIp is string && xRealIp.trim().length() > 0 {
        return xRealIp.trim();
    }
    return ();
}

# ===== API response helpers (see note/API-Response-Standard.md) =====

# + data - the response payload
# + message - human-readable success message
# + pagination - optional pagination metadata, included in `meta.pagination` when present
# + return - the standard success `ApiResponse` envelope
public function successResponse(anydata data, string message = "Success",
        models:Pagination? pagination = ()) returns models:ApiResponse {
    models:ResponseMeta meta = {};
    if pagination is models:Pagination {
        meta.pagination = pagination;
    }
    return {
        success: true,
        message: message,
        data: data,
        errors: (),
        meta: meta
    };
}

public function errorResponse(string code, string message, anydata? details = ()) returns models:ApiResponse {
    return {
        success: false,
        message: message,
        data: (),
        errors: {code: code, message: message, details: details},
        meta: {}
    };
}

# ===== AppError constructors =====

# + message - the error message
# + return - a 401 UNAUTHORIZED AppError
public function unauthorizedError(string message) returns models:AppError {
    return error models:AppError(message, code = "UNAUTHORIZED", statusCode = 401);
}

public function validationError(string message) returns models:AppError {
    return error models:AppError(message, code = "VALIDATION_ERROR", statusCode = 400);
}

public function internalError(string message) returns models:AppError {
    return error models:AppError(message, code = "INTERNAL_ERROR", statusCode = 500);
}

public function forbiddenError(string message) returns models:AppError {
    return error models:AppError(message, code = "FORBIDDEN", statusCode = 403);
}

public function notFoundError(string message) returns models:AppError {
    return error models:AppError(message, code = "NOT_FOUND", statusCode = 404);
}

public function conflictError(string message) returns models:AppError {
    return error models:AppError(message, code = "CONFLICT", statusCode = 409);
}

# Decodes the claims of a WSO2 IS id_token (JWT) without re-verifying the signature —
# the token arrives straight from IS's own token endpoint over TLS, so decoding is enough
# to surface user info (sub, email, name, ...) to the frontend.
#
# + idToken - the id_token returned by the WSO2 IS token endpoint
# + return - the decoded JWT payload as a map, or an error if the token is malformed
public function decodeIdTokenClaims(string idToken) returns map<json>|error {
    [jwt:Header, jwt:Payload] [_, payload] = check jwt:decode(idToken);
    json payloadJson = payload.toJson();
    return check payloadJson.cloneWithType();
}

# Builds the HTTP Basic `Authorization` header value for authenticating the OAuth2 client
# against the introspection and revocation endpoints (client_secret_basic).
#
# + return - `"Basic <base64(clientId:clientSecret)>"`
public function basicAuthHeader() returns string {
    string credentials = config:clientId + ":" + config:clientSecret;
    return "Basic " + credentials.toBytes().toBase64();
}

# Extracts the bearer token from an incoming `Authorization` header value.
#
# + authorization - the raw `Authorization` header value (may be nil if absent)
# + return - the token, or an UNAUTHORIZED AppError if the header is missing/malformed
public function bearerToken(string? authorization) returns string|models:AppError {
    if authorization is () || authorization.trim().length() == 0 {
        return unauthorizedError("Authorization header tidak ditemukan");
    }
    string header = authorization.trim();
    if !header.startsWith("Bearer ") {
        return unauthorizedError("Authorization header harus berupa Bearer token");
    }
    string token = header.substring(7).trim();
    if token.length() == 0 {
        return unauthorizedError("Bearer token kosong");
    }
    return token;
}

# Extracts the `sub` (subject) claim from the caller's WSO2 IS access token, to fill the
# `created_by`/`updated_by` audit columns. Only decodes the JWT (no signature re-check) —
# the declarative `@http:ServiceConfig` guard already verified it via JWKS before the
# resource ran, so decoding to read `sub` is enough (same reasoning as `decodeIdTokenClaims`).
#
# + authorization - the raw `Authorization` header value (may be nil if absent)
# + return - the `sub` claim, or an UNAUTHORIZED AppError if the header/token is invalid
public function subjectFromAccessToken(string? authorization) returns string|models:AppError {
    string|models:AppError token = bearerToken(authorization);
    if token is models:AppError {
        return token;
    }

    [jwt:Header, jwt:Payload]|jwt:Error decoded = jwt:decode(token);
    if decoded is jwt:Error {
        return unauthorizedError("Access token tidak valid");
    }

    string? sub = decoded[1].sub;
    if sub is () {
        return unauthorizedError("Access token tidak memuat klaim sub");
    }
    return sub;
}
