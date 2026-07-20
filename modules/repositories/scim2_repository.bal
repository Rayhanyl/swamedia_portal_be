import ballerina/http;
import rayha/swamedia_portal_be.config;

# ===== Manajemen User — SCIM2 client (WSO2 IS user provisioning) =====
#
# The WRITE half of Manajemen User. Per schema implementation note #2, user create/update/status/role
# changes go through WSO2 IS's SCIM2 REST API — never this database. This file wraps the SCIM2 calls
# the module needs, reusing the shared `oauth2Client` (scoped to `iamBaseUrl`) and the module-private
# `errorFromResponse` helper from repositories.bal.
#
# Auth model: EVERY SCIM2 write and read in this file runs as the Super Admin IS account (HTTP Basic,
# `config:scimAdminUsername`/`scimAdminPassword` — see `scimAdminBasicAuthHeader`). This module
# originally split writes across two credentials (an app-level `client_credentials` token for
# create/update-profile/role/status, Super Admin Basic only for the fuller `/akun`+`/password`
# writes), but the app-level token path 403'd on this deployment ("Operation is not permitted") —
# WSO2 IS 7.x's API Authorization model never granted the OAuth2 app access to the SCIM2 Users API
# resource, only the Super Admin account has it (confirmed working — see URL-Doc-IS7, whose examples
# all use Basic Auth). Consolidating everything onto the one proven-working credential unblocks the
# module without needing WSO2 IS Console access.
#
# NOTE (verification): unlike the DB-backed modules, this path could not be exercised end-to-end here
# — it needs a live WSO2 IS with SCIM2 enabled. The request shapes follow the SCIM2 spec + WSO2's
# custom-claim extension (`config:scimRoleClaimSchema`); the exact schema URN for `swaportal_role_id`
# is deployment-specific and is left configurable.

# The SCIM2 core User schema URN (constant across deployments).
const string SCIM_USER_SCHEMA = "urn:ietf:params:scim:schemas:core:2.0:User";
# The SCIM2 PatchOp message schema URN.
const string SCIM_PATCHOP_SCHEMA = "urn:ietf:params:scim:api:messages:2.0:PatchOp";

# Creates a user in WSO2 IS via SCIM2 and returns the new user's SCIM `id` (the portal's subject_id).
# Always stamps `swaportal_group_id` (`config:appGroupId`) so the new user is a portal member from
# creation — without it, `services:buildLoginResponse`'s membership gate would reject their very
# first login. `swaportal_role_id` is only written when `roleId` is given.
#
# + userName - the login username
# + email - the user's email
# + nama - the user's display name
# + password - the initial password
# + roleId - optional portal role id written to the `swaportal_role_id` custom attribute
# + return - the created user's SCIM id, or an error
public function scimCreateUser(string userName, string email, string nama, string password, int? roleId)
        returns string|error {
    map<json> customClaims = {};
    customClaims[config:appGroupClaim] = config:appGroupId;
    if roleId is int {
        customClaims[config:scimRoleClaimAttribute] = roleId.toString();
    }

    json[] schemas = [SCIM_USER_SCHEMA, config:scimRoleClaimSchema];
    map<json> userBody = {
        "userName": userName,
        "password": password,
        "name": {"formatted": nama, "givenName": nama},
        "emails": [{"primary": true, "value": email}]
    };
    userBody[config:scimRoleClaimSchema] = customClaims;
    userBody["schemas"] = schemas;

    http:Request req = new;
    req.setHeader("Authorization", scimAdminBasicAuthHeader());
    req.setHeader("Content-Type", "application/scim+json");
    req.setJsonPayload(userBody);

    http:Response resp = check oauth2Client->post(config:scimUsersPath, req);
    if resp.statusCode != 201 {
        return errorFromResponse("WSO2 SCIM2 create user", resp);
    }
    json payload = check resp.getJsonPayload();
    return (check payload.id).toString();
}

# Issues a SCIM2 `replace` PATCH against a user with the given attribute map.
#
# + userId - the SCIM user id (subject_id)
# + value - the SCIM attributes to replace
# + return - an error if the PATCH failed
function scimPatch(string userId, map<json> value) returns error? {
    json patchBody = {
        "schemas": [SCIM_PATCHOP_SCHEMA],
        "Operations": [{"op": "replace", "value": value}]
    };
    http:Request req = new;
    req.setHeader("Authorization", scimAdminBasicAuthHeader());
    req.setHeader("Content-Type", "application/scim+json");
    req.setJsonPayload(patchBody);

    http:Response resp = check oauth2Client->patch(config:scimUsersPath + "/" + userId, req);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 SCIM2 patch user " + userId, resp);
    }
}

# Updates a user's display name + email via SCIM2 PATCH.
#
# + userId - the SCIM user id (subject_id)
# + nama - the new display name
# + email - the new email
# + return - an error if the update failed
public function scimUpdateProfile(string userId, string nama, string email) returns error? {
    map<json> value = {
        "name": {"formatted": nama, "givenName": nama},
        "emails": [{"primary": true, "value": email}]
    };
    return scimPatch(userId, value);
}

# Sets (or clears) the `swaportal_role_id` custom attribute via SCIM2 PATCH.
#
# + userId - the SCIM user id (subject_id)
# + roleId - the portal role id, or () to clear it (written as an empty string)
# + return - an error if the update failed
public function scimSetRole(string userId, int? roleId) returns error? {
    map<json> roleClaim = {};
    roleClaim[config:scimRoleClaimAttribute] = roleId is int ? roleId.toString() : "";
    map<json> value = {};
    value[config:scimRoleClaimSchema] = roleClaim;
    return scimPatch(userId, value);
}

# Enables/disables a user (SCIM `active`) via SCIM2 PATCH.
#
# + userId - the SCIM user id (subject_id)
# + active - true to enable, false to disable
# + return - an error if the update failed
public function scimSetStatus(string userId, boolean active) returns error? {
    map<json> value = {"active": active};
    return scimPatch(userId, value);
}

# ===== Super Admin-credentialed reads/writes =====
#
# `scimAdminBasicAuthHeader` is shared by every SCIM2 call in this file (the functions above included
# — see the module-level auth-model note at the top). Originally added just for the fuller Akun Saya
# / Manajemen User "akun" account writes (self-service password/email/name/phone, and the admin
# equivalent that can reset another user's password), since those specifically need to run as a real
# WSO2 IS Administrator. See config:scimAdminUsername/scimAdminPassword.

# Builds the HTTP Basic `Authorization` header for the Super Admin IS account.
#
# + return - `"Basic <base64(scimAdminUsername:scimAdminPassword)>"`
function scimAdminBasicAuthHeader() returns string {
    string credentials = config:scimAdminUsername + ":" + config:scimAdminPassword;
    return "Basic " + credentials.toBytes().toBase64();
}

# Issues a SCIM2 PATCH (a list of `replace` operations) against a user using the Super Admin IS
# account (HTTP Basic), and returns the full updated resource WSO2 IS reports back — so callers can
# build their response straight from it instead of a second round trip.
#
# Each caller-supplied operation is a `{"op": "replace", "value": {...}}` object; splitting the
# update into one op per attribute/schema sub-attribute mirrors the shape WSO2 IS accepts (see
# URL-Doc-IS7 §3) and lets a partial complex attribute (e.g. only `name.givenName`) replace just that
# sub-attribute without clobbering its siblings.
#
# + userId - the SCIM user id (subject_id) to patch
# + operations - the SCIM2 PatchOp operations to apply
# + extraSchemas - additional schema URNs to declare on the PATCH body (e.g. the WSO2 custom-claim
# schema, required when an operation touches a key under that schema)
# + return - the updated SCIM user resource, or an error if the PATCH failed
public function scimAdminPatch(string userId, json[] operations, string[] extraSchemas = [])
        returns json|error {
    json[] schemas = [SCIM_PATCHOP_SCHEMA];
    foreach string s in extraSchemas {
        schemas.push(s);
    }
    json patchBody = {
        "schemas": schemas,
        "Operations": operations
    };
    http:Request req = new;
    req.setHeader("Authorization", scimAdminBasicAuthHeader());
    req.setHeader("Content-Type", "application/scim+json");
    req.setJsonPayload(patchBody);

    http:Response resp = check oauth2Client->patch(config:scimUsersPath + "/" + userId, req);
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 SCIM2 admin patch user " + userId, resp);
    }
    return resp.getJsonPayload();
}

# Fetches a user's full SCIM2 resource using the Super Admin IS account (HTTP Basic) — the read
# counterpart of `scimAdminPatch`, used to prefill the Akun Saya / Manajemen User "akun" edit forms
# with the caller's/target's current WSO2 IS identity. Follows the same `T?|error` convention as the
# DB-backed `find*` repository functions: () means "no such user", not an error.
#
# + userId - the SCIM user id (subject_id) to fetch
# + return - the SCIM user resource, () if WSO2 IS reports 404, or an error for anything else
public function scimAdminGet(string userId) returns json?|error {
    http:Response resp = check oauth2Client->get(config:scimUsersPath + "/" + userId,
            {"Authorization": scimAdminBasicAuthHeader()});
    if resp.statusCode == 404 {
        return ();
    }
    if resp.statusCode != 200 {
        return errorFromResponse("WSO2 SCIM2 admin get user " + userId, resp);
    }
    return resp.getJsonPayload();
}
