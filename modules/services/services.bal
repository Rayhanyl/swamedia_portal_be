import ballerina/crypto;
import ballerina/log;
import rayha/swamedia_portal_be.config;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# How long a cached userinfo lookup stays valid before we hit WSO2 IS again.
const int USERINFO_CACHE_TTL_SECONDS = 60;

# Builds the public login response (token set + decoded user claims) from a WSO2 token response.
# Shared by `login`, `exchangeToken`, and `refresh`.
#
# + tokenResp - the raw token response from WSO2 IS
# + return - the public login response, or an AppError if the id_token claims couldn't be decoded
function buildLoginResponse(models:TokenResponse tokenResp) returns models:LoginResponse|models:AppError {
    string? idToken = tokenResp.id_token;
    map<json> user = {};
    if idToken is string {
        map<json>|error claims = utils:decodeIdTokenClaims(idToken);
        if claims is error {
            log:printError("Failed to decode id_token claims", claims);
            return utils:internalError("Gagal membaca data user dari id_token");
        }
        user = claims;
        // Portal membership gate: only users provisioned into this application (carrying the
        // `swaportal_group_id` claim) may sign in. Rejecting here gives a clear message instead
        // of letting every later business call 403 on the declarative scope check.
        if !hasAppGroup(user) {
            return utils:forbiddenError("Akun Anda tidak memiliki akses ke portal ini");
        }
    }

    return {
        accessToken: tokenResp.access_token,
        refreshToken: tokenResp.refresh_token,
        idToken: tokenResp.id_token,
        tokenType: tokenResp.token_type,
        expiresIn: tokenResp.expires_in,
        scope: tokenResp.scope,
        user: user
    };
}

# Whether the decoded token claims place the user in this application's access group
# (`config:appGroupClaim` == `config:appGroupId`). The claim arrives as a single string in
# WSO2's tokens, but an array is tolerated in case the deployment maps it as multi-valued.
#
# + claims - the decoded id_token/userinfo claims
# + return - true if the user belongs to the portal application group
function hasAppGroup(map<json> claims) returns boolean {
    json? group = claims[config:appGroupClaim];
    if group is string {
        return group == config:appGroupId;
    }
    if group is json[] {
        foreach json value in group {
            if value is string && value == config:appGroupId {
                return true;
            }
        }
    }
    return false;
}

# Verifies portal membership from the (cached) live `userInfo` lookup rather than the access
# token's own embedded claims. WSO2 IS has been observed to intermittently omit
# `swaportal_group_id`/`swaportal_role_id` from the JWT access token at issuance — sometimes
# present, sometimes not, for the very same user across different logins — even though the
# id_token and `/oauth2/userinfo` response both carry it reliably. `TokenDenylistInterceptor`
# (main.bal) calls this on every request in place of the declarative JWKS `scopes` gate that used
# to check the access token's own claim directly (removed for that reason).
#
# + accessToken - the caller's raw Bearer access token
# + return - () if the caller belongs to the app group, or an UNAUTHORIZED/FORBIDDEN AppError
public function verifyAppGroupMembership(string accessToken) returns models:AppError? {
    map<json>|models:AppError info = userInfo(accessToken);
    if info is models:AppError {
        return info;
    }
    if !hasAppGroup(info) {
        return utils:forbiddenError("Akun Anda tidak memiliki akses ke portal ini");
    }
    return ();
}

# Starts the WSO2 IS authentication flow and surfaces the flowId + available authenticators.
#
# + return - the flowId and authenticator list, or an AppError
public function initFlow() returns models:InitResponse|models:AppError {
    models:AuthInitResponse|error initResp = repositories:initAuthFlow();
    if initResp is error {
        log:printError("initAuthFlow failed", initResp);
        return utils:internalError("Gagal memulai proses login, silakan coba lagi nanti");
    }

    return {
        flowId: initResp.flowId,
        authenticators: initResp.nextStep.authenticators
    };
}

# Orchestrates the full WSO2 IS login flow (init -> authenticate -> token exchange) behind
# a single call, so the frontend only ever needs to send username/password.
#
# + payload - username and password entered by the user
# + return - the token set plus decoded user claims, or an AppError describing what went wrong
public function login(models:LoginRequest payload) returns models:LoginResponse|models:AppError {
    models:AuthInitResponse|error initResp = repositories:initAuthFlow();
    if initResp is error {
        log:printError("initAuthFlow failed", initResp);
        return utils:internalError("Gagal memulai proses login, silakan coba lagi nanti");
    }

    models:AuthInitAuthenticator? localAuthenticator = ();
    foreach models:AuthInitAuthenticator authenticator in initResp.nextStep.authenticators {
        if authenticator.idp == "LOCAL" {
            localAuthenticator = authenticator;
            break;
        }
    }

    if localAuthenticator is () {
        return utils:internalError("Authenticator Username & Password tidak tersedia di Identity Server");
    }

    models:AuthnResponse|error authnResp = repositories:submitUsernamePassword(
            initResp.flowId, localAuthenticator.authenticatorId, payload.username, payload.password);
    if authnResp is error {
        log:printError("submitUsernamePassword failed", authnResp);
        return utils:internalError("Gagal melakukan autentikasi, silakan coba lagi nanti");
    }

    models:AuthnData? authData = authnResp.authData;
    if authnResp.flowStatus != "SUCCESS_COMPLETED" || authData is () {
        return utils:unauthorizedError("Username atau password salah");
    }

    return exchangeToken(authData.code);
}

# Exchanges an authorization code for a token set (authorization_code grant). This is the choke
# point both `login` (username/password) and the `/token` endpoint (direct code exchange) funnel
# through, so it's also where a successful login's claims get mirrored into `user_cache` — see
# `syncUserCacheFromLogin` (user_cache_service.bal) for why `refresh` is deliberately excluded.
#
# + code - the authorization code
# + return - the token set plus decoded user claims, or an AppError
public function exchangeToken(string code) returns models:LoginResponse|models:AppError {
    models:TokenResponse|error tokenResp = repositories:exchangeCodeForToken(code);
    if tokenResp is error {
        log:printError("exchangeCodeForToken failed", tokenResp);
        return utils:internalError("Gagal mengambil access token, silakan coba lagi nanti");
    }
    models:LoginResponse|models:AppError result = buildLoginResponse(tokenResp);
    if result is models:LoginResponse {
        syncUserCacheFromLogin(result.user);
    }
    return result;
}

# Trades a refresh token for a fresh token set (refresh_token grant).
#
# + payload - the refresh token
# + return - the new token set plus decoded user claims, or an AppError
public function refresh(models:RefreshRequest payload) returns models:LoginResponse|models:AppError {
    models:TokenResponse|error tokenResp = repositories:refreshToken(payload.refreshToken);
    if tokenResp is error {
        log:printError("refreshToken failed", tokenResp);
        return utils:unauthorizedError("Refresh token tidak valid atau sudah expired");
    }
    return buildLoginResponse(tokenResp);
}

# Fetches the OIDC user claims for the given access token. Demonstrates the cache-aside
# pattern future business logic can reuse via `repositories:cacheGet`/`cacheSet`: Redis is
# a nice-to-have here, not a hard dependency — if it's unreachable, we silently fall back
# to calling WSO2 IS directly instead of failing the request.
#
# + accessToken - a valid access token
# + return - the userinfo claims, or an AppError (401 when IS rejects the token)
public function userInfo(string accessToken) returns map<json>|models:AppError {
    string cacheKey = "userinfo:" + crypto:hashSha256(accessToken.toBytes()).toBase16();

    json|error cached = repositories:cacheGet(cacheKey);
    if cached is map<json> {
        return cached;
    } else if cached is error {
        log:printError("userinfo cache read failed, falling back to WSO2 IS", cached);
    }

    map<json>|error info = repositories:getUserInfo(accessToken);
    if info is error {
        log:printError("getUserInfo failed", info);
        return utils:unauthorizedError("Access token tidak valid atau sudah expired");
    }

    error? cacheErr = repositories:cacheSet(cacheKey, info, ttlSeconds = USERINFO_CACHE_TTL_SECONDS);
    if cacheErr is error {
        log:printError("userinfo cache write failed", cacheErr);
    }

    return info;
}

# Introspects a token.
#
# + payload - the token to inspect and an optional token_type_hint
# + return - the introspection result, or an AppError
public function introspect(models:IntrospectRequest payload) returns models:IntrospectResponse|models:AppError {
    models:IntrospectResponse|error result = repositories:introspect(payload.token, payload?.tokenTypeHint);
    if result is error {
        log:printError("introspect failed", result);
        return utils:internalError("Gagal memeriksa token, silakan coba lagi nanti");
    }
    return result;
}

# Revokes a token at WSO2 IS, and denylists it locally so it's rejected on the next
# request instead of staying valid until it naturally expires.
#
# + payload - the token to revoke and an optional token_type_hint
# + return - an AppError if the revocation failed, () on success
public function revoke(models:RevokeRequest payload) returns models:AppError? {
    error? result = repositories:revoke(payload.token, payload?.tokenTypeHint);
    if result is error {
        log:printError("revoke failed", result);
        return utils:internalError("Gagal mencabut token, silakan coba lagi nanti");
    }
    utils:denylistToken(payload.token);
    return ();
}

# Ends the user's session on WSO2 IS, and denylists the access token (if provided) so it's
# rejected locally on the next request instead of staying valid until it naturally expires.
#
# + payload - the id_token obtained at login time, plus the access token to invalidate
# + return - an AppError if the logout request failed, () on success
public function logout(models:LogoutRequest payload) returns models:AppError? {
    error? result = repositories:logout(payload.idToken);
    if result is error {
        log:printError("logout failed", result);
        return utils:internalError("Gagal melakukan logout, silakan coba lagi nanti");
    }
    string? accessToken = payload?.accessToken;
    if accessToken is string {
        utils:denylistToken(accessToken);
    }
    return ();
}
