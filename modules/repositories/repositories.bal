import ballerina/http;
import ballerina/url;
import rayha/swamedia_portal_be.config;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.utils;

# Single HTTP client scoped to the WSO2 IS host; all endpoint paths come from config.
final http:Client oauth2Client = check new (config:iamBaseUrl);

function buildFormBody(map<string> params) returns string|error {
    string[] parts = [];
    foreach [string, string] [key, value] in params.entries() {
        string encodedValue = check url:encode(value, "UTF-8");
        parts.push(key + "=" + encodedValue);
    }
    return string:'join("&", ...parts);
}

# Builds an error carrying the WSO2 IS response body, so the real cause (e.g.
# `invalid_client`, `invalid_grant`) is visible in server logs instead of just a status code.
#
# + action - short label identifying which WSO2 IS call failed, prefixed onto the error message
# + resp - the failed response
# + return - an error embedding the action label, status code, and response body
function errorFromResponse(string action, http:Response resp) returns error {
    string body = "";
    string|error textPayload = resp.getTextPayload();
    if textPayload is string {
        body = textPayload;
    }
    return error(action + " failed with status " + resp.statusCode.toString() + ": " + body);
}

# Step 1 — starts the WSO2 IS authentication flow.
#
# + return - the flowId and the list of available authenticators, or an error
public function initAuthFlow() returns models:AuthInitResponse|error {
    string body = check buildFormBody({
        "client_id": config:clientId,
        "client_secret": config:clientSecret,
        "response_type": "code",
        "redirect_uri": config:redirectUri,
        "scope": config:loginScope,
        "response_mode": "direct"
    });

    http:Request req = new;
    req.setTextPayload(body, "application/x-www-form-urlencoded");

    http:Response resp = check oauth2Client->post(config:authorizePath, req);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 IS init request", resp);
    }

    json payload = check resp.getJsonPayload();
    return check payload.cloneWithType();
}

# Step 2 — submits username/password against the LOCAL authenticator selected from the init step.
#
# + flowId - the flowId returned by `initAuthFlow`
# + authenticatorId - the authenticatorId of the LOCAL (Username & Password) authenticator
# + username - username entered by the user
# + password - password entered by the user
# + return - the authentication result, containing the authorization code on success, or an error
public function submitUsernamePassword(string flowId, string authenticatorId, string username, string password)
        returns models:AuthnResponse|error {
    json body = {
        flowId,
        selectedAuthenticator: {
            authenticatorId,
            params: {
                username,
                password
            }
        }
    };

    http:Response resp = check oauth2Client->post(config:authnPath, body);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 IS authenticate request", resp);
    }

    json payload = check resp.getJsonPayload();
    return check payload.cloneWithType();
}

# Step 3 — exchanges the authorization code for an access/refresh/id token.
#
# + code - the authorization code returned in `authData.code` from `submitUsernamePassword`
# + return - the token set, or an error
public function exchangeCodeForToken(string code) returns models:TokenResponse|error {
    string body = check buildFormBody({
        "client_id": config:clientId,
        "client_secret": config:clientSecret,
        "code": code,
        "grant_type": "authorization_code",
        "redirect_uri": config:redirectUri
    });

    return postToken(body);
}

# Trades a refresh token for a fresh token set (refresh_token grant).
#
# + refreshToken - the refresh token obtained at login time
# + return - the new token set, or an error
public function refreshToken(string refreshToken) returns models:TokenResponse|error {
    string body = check buildFormBody({
        "client_id": config:clientId,
        "client_secret": config:clientSecret,
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "scope": config:loginScope
    });

    return postToken(body);
}

# Shared POST to the token endpoint for the authorization_code and refresh_token grants.
#
# + body - the pre-built `application/x-www-form-urlencoded` request body
# + return - the token set, or an error
function postToken(string body) returns models:TokenResponse|error {
    http:Request req = new;
    req.setTextPayload(body, "application/x-www-form-urlencoded");

    http:Response resp = check oauth2Client->post(config:tokenPath, req);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 IS token request", resp);
    }

    json payload = check resp.getJsonPayload();
    return check payload.cloneWithType();
}

# Fetches the OIDC user claims for the given access token.
#
# + accessToken - a valid access token
# + return - the userinfo claims, or an error (including when IS rejects the token)
public function getUserInfo(string accessToken) returns map<json>|error {
    http:Response resp = check oauth2Client->get(config:userinfoPath, {"Authorization": "Bearer " + accessToken});
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 IS userinfo request", resp);
    }

    json payload = check resp.getJsonPayload();
    return check payload.cloneWithType();
}

# Introspects a token (RFC 7662) using client_secret_basic authentication.
#
# + token - the token to inspect
# + hint - optional token_type_hint ("access_token" or "refresh_token")
# + return - the introspection result (`active` plus claims), or an error
public function introspect(string token, string? hint) returns models:IntrospectResponse|error {
    map<string> params = {"token": token};
    if hint is string {
        params["token_type_hint"] = hint;
    }
    string body = check buildFormBody(params);

    http:Request req = new;
    req.setHeader("Authorization", utils:basicAuthHeader());
    req.setTextPayload(body, "application/x-www-form-urlencoded");

    http:Response resp = check oauth2Client->post(config:introspectPath, req);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 IS introspect request", resp);
    }

    json payload = check resp.getJsonPayload();
    return check payload.cloneWithType();
}

# Revokes a token (RFC 7009) using client_secret_basic authentication.
#
# + token - the access or refresh token to revoke
# + hint - optional token_type_hint ("access_token" or "refresh_token")
# + return - an error if the revocation request failed
public function revoke(string token, string? hint) returns error? {
    map<string> params = {"token": token};
    if hint is string {
        params["token_type_hint"] = hint;
    }
    string body = check buildFormBody(params);

    http:Request req = new;
    req.setHeader("Authorization", utils:basicAuthHeader());
    req.setTextPayload(body, "application/x-www-form-urlencoded");

    http:Response resp = check oauth2Client->post(config:revokePath, req);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 IS revoke request", resp);
    }
}

# Ends the user's session on WSO2 IS.
#
# + idToken - the id_token obtained from `exchangeCodeForToken`
# + return - an error if the logout request failed
public function logout(string idToken) returns error? {
    string body = check buildFormBody({
        "id_token_hint": idToken,
        "response_mode": "direct"
    });

    http:Request req = new;
    req.setTextPayload(body, "application/x-www-form-urlencoded");

    http:Response resp = check oauth2Client->post(config:logoutPath, req);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 IS logout request", resp);
    }
}
