# WSO2 Identity Server OAuth2 client credentials.
# Override these via a local `Config.toml` (gitignored) — empty defaults only let
# `bal build`/`bal test` run without one; real login/logout calls need real values.
public configurable string clientId = "";
public configurable string clientSecret = "";
public configurable string redirectUri = "";

# Base host for all WSO2 IS endpoints. Individual endpoint paths are appended to this.
public configurable string iamBaseUrl = "https://iam.apicentrum.biz.id";

# Scope requested during the login flow. Per OIDC spec, the `email` claim is ONLY released in the
# id_token if the `email` scope is requested (`profile` alone does not imply it) — this must include
# `email` for `services:syncUserCacheFromLogin` (user_cache_service.bal) to have an email to mirror
# into `user_cache`. `profile` covers `name`/`given_name`/`family_name`.
public configurable string loginScope = "openid internal_login profile email swaportal_identity";

# Port the backend HTTP listener binds to.
public configurable int port = 8080;

# WSO2 IS endpoint paths (relative to `iamBaseUrl`). Kept configurable so no URL is
# hardcoded in the client layer; defaults match a standard WSO2 IS 7.x deployment.
public configurable string authorizePath = "/oauth2/authorize";
public configurable string authnPath = "/oauth2/authn";
public configurable string tokenPath = "/oauth2/token";
public configurable string userinfoPath = "/oauth2/userinfo";
public configurable string introspectPath = "/oauth2/introspect";
public configurable string revokePath = "/oauth2/revoke";
public configurable string logoutPath = "/oidc/logout";
public configurable string jwksPath = "/oauth2/jwks";

# ===== SCIM2 (Manajemen User write operations) =====
# The write path for Manajemen User goes through WSO2 IS's SCIM2 API (schema implementation note #2),
# NOT this database — see modules/repositories/scim2_repository.bal. Every SCIM2 call (create/update
# profile/role/status/akun/password) runs as the Super Admin IS account below (HTTP Basic) — an
# earlier app-level `client_credentials` token path was dropped after WSO2 IS 7.x's API Authorization
# rejected it with 403 ("Operation is not permitted") on this deployment; only the Super Admin
# account is actually authorized for the SCIM2 Users API here (confirmed working — see URL-Doc-IS7).
public configurable string scimUsersPath = "/scim2/Users";
# The SCIM schema URN the WSO2 custom attribute `swaportal_role_id` lives under, and the attribute
# name itself. On this deployment the portal's custom claims (`swaportal_role_id`,
# `swaportal_group_id`) are exposed under the custom-User extension schema — confirmed by the live
# SCIM2 GET/PATCH payloads (see URL-Doc-IS7). Note this is NOT `urn:scim:wso2:schema`, which instead
# carries WSO2's own claims (`emailAddresses`, `emailOTPDisabled`, …).
public configurable string scimRoleClaimSchema = "urn:scim:schemas:extension:custom:User";
public configurable string scimRoleClaimAttribute = "swaportal_role_id";

# ===== SCIM2 — Super Admin account (HTTP Basic) =====
# The actual WSO2 IS Administrator account every SCIM2 call authenticates as — see
# scim2_repository.bal:scimAdminBasicAuthHeader. NEVER hardcode real values here or anywhere in
# source — set them only in the local, gitignored Config.toml / Config.docker.toml (see
# Config.docker.toml.example).
public configurable string scimAdminUsername = "";
public configurable string scimAdminPassword = "";

# ===== Application access group (portal membership gate) =====
# Only WSO2 IS users provisioned into the portal application may call the business API. WSO2
# stamps the group into every access/id token as the custom claim `swaportal_group_id`
# (value `swamedia_portal_app` for this app). Two independent checks use these:
#   1. Declarative — every protected service's `@http:ServiceConfig` auth block sets
#      `scopeKey: appGroupClaim` + `scopes: [appGroupId]`, so Ballerina's JWKS auth returns 403
#      (signature-verified) before any resource runs if the token lacks the group.
#   2. At login — `services:buildLoginResponse` rejects the sign-in up front with a clear message
#      if the decoded id_token doesn't carry the group, instead of letting every later call 403.
# Both are configurable so a different deployment/app can retarget the claim + value.
public configurable string appGroupClaim = "swaportal_group_id";
public configurable string appGroupId = "swamedia_portal_app";

# ===== Access token (JWT) validation for business endpoints =====
# Used by the declarative `@http:ServiceConfig` JWT auth on protected services (see
# main.bal) — Ballerina validates signature (via JWKS), expiry, issuer and audience
# on every request automatically and returns 401 before the resource function runs.

# Must match the `iss` claim WSO2 puts in access tokens (see discovery doc's `issuer`).
public configurable string jwtIssuer = "https://iam.apicentrum.biz.id/oauth2/token";

# Full URL to WSO2's JWKS endpoint (used to fetch/cache the public keys for signature checks).
public configurable string jwksUrl = "https://iam.apicentrum.biz.id/oauth2/jwks";

# ===== CORS (browser requests from the frontend app) =====
# Applied to every service in main.bal via `@http:ServiceConfig { cors: {...} }`. Only
# relevant when a browser calls the API directly from a different origin — server-to-server
# calls (e.g. a Next.js API route proxying to this backend) are never subject to CORS.
# Override with the real frontend origin(s) via Config.toml; the default only covers local
# Next.js dev (`next dev` on its default port).
public configurable string[] corsAllowedOrigins = ["http://localhost:3000"];

# ===== PostgreSQL (primary application database) =====
# See modules/repositories/db.bal for the client. Connection is lazy (established on
# first actual use), so `bal build`/`bal test` never require Postgres to be running —
# only `bal run` (or a test that actually queries the DB) does.
public configurable string dbHost = "localhost";
public configurable int dbPort = 5432;
public configurable string dbName = "swamedia_portal_db";
public configurable string dbUser = "postgres";
public configurable string dbPassword = "";
public configurable int dbMaxOpenConnections = 10;

# ===== Redis (generic cache for future business processes) =====
# See modules/repositories/cache.bal for the client + helper functions. Connection is
# lazy (established on first actual use), so `bal build`/`bal test` never require Redis
# to be running — only `bal run` (or a test that actually calls a cache function) does.
public configurable string redisHost = "localhost";
public configurable int redisPort = 6379;
public configurable string redisPassword = "";
public configurable int redisDatabase = 0;
public configurable int redisConnectionTimeoutSeconds = 3;

# ===== RBAC permission enforcement (PermissionInterceptor in main.bal) =====
# Master switch for the per-service role/permission middleware. When true (secure default),
# every gated business service checks the caller's role_permission matrix (resolved from the
# `swaportal_role_id` userinfo claim, cached in Redis per schema note #7) and returns 403 if the
# role lacks the CRUD/approve/export bit the request needs. Set to false ONLY during the
# transition period before WSO2 IS users have their `swaportal_role_id` custom attribute
# provisioned — with it off, an authenticated (JWKS-valid) token may call any gated endpoint.
public configurable boolean permissionEnforcementEnabled = true;
