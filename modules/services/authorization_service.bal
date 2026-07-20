import ballerina/log;
import rayha/swamedia_portal_be.config;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== RBAC — Authorization (permission enforcement) service =====
#
# The enforcement half of the RBAC data model that role_service / role_permission_service /
# role_menu_service already administer. `requirePermission` is the single guard the
# `PermissionInterceptor` (main.bal) calls once per request:
#
#   1. Resolve the caller's role id from the `swaportal_role_id` claim in their WSO2 userinfo
#      (reusing the existing 60s-cached `userInfo` lookup — schema implementation note #7/#2).
#   2. Load that role's permission matrix, cache-aside from Redis under `role:{id}:permissions`
#      (the same key role_permission_service invalidates the instant the matrix is edited, so a
#      short TTL here is only a safety net, not the primary freshness mechanism).
#   3. Allow only if the role holds the specific bit (can_create/read/update/delete/approve/
#      export) the request needs on the target modul; otherwise 403.
#
# SCOPE (row-level) IS NOT ENFORCED HERE. `role_permission.scope = UNIT_SENDIRI` is loaded and
# cached but this layer only gates the coarse CRUD/approve/export verbs; filtering list/detail
# rows down to the caller's own unit touches every repository query and is deliberately a
# separate, later layer. TODO(rbac-scope): apply UNIT_SENDIRI row filtering in the repositories.
# The Direktur-Utama unit check for approvals (schema note #8) likewise remains a service-layer
# concern that is not yet wired — this guard only checks the role-level can_approve bit.

# TTL safety net for a role's cached permission matrix. Freshness normally comes from
# role_permission_service invalidating `role:{id}:permissions` on save, not from expiry.
const int ROLE_PERMISSION_CACHE_TTL_SECONDS = 300;

# The WSO2 userinfo claim carrying the portal role id (provisioned on the IS user via SCIM2 —
# schema implementation note #2).
const string ROLE_CLAIM = "swaportal_role_id";

# Authorizes one request: () when allowed, a FORBIDDEN/UNAUTHORIZED `AppError` when denied, or a
# plain `error` if the permission lookup itself failed (infrastructure). A no-op when
# `config:permissionEnforcementEnabled` is false.
#
# + accessToken - the caller's raw Bearer access token (already JWKS-valid at the HTTP layer)
# + modulKode - the target modul's `kode_modul` (e.g. "TAGIHAN")
# + action - one of create / read / update / delete / approve / export
# + return - () if permitted, an AppError if denied, or an error if the lookup failed
public function requirePermission(string accessToken, string modulKode, string action)
        returns models:AppError|error? {
    if !config:permissionEnforcementEnabled {
        return ();
    }

    int|models:AppError roleId = resolveRoleId(accessToken);
    if roleId is models:AppError {
        return roleId;
    }

    map<models:RolePermissionItem> matrix = check loadRolePermissions(roleId);
    models:RolePermissionItem? grant = matrix[modulKode];
    if grant is () {
        return utils:forbiddenError("Anda tidak memiliki akses ke modul " + modulKode);
    }
    if !actionAllowed(grant, action) {
        return utils:forbiddenError(
            "Anda tidak memiliki hak '" + action + "' pada modul " + modulKode);
    }
    return ();
}

# Resolves the caller's role id from their (cached) userinfo `swaportal_role_id` claim, coping
# with the claim arriving as a JSON number or a string.
#
# + accessToken - the caller's raw Bearer access token
# + return - the role id, or an UNAUTHORIZED/FORBIDDEN AppError if it can't be resolved
function resolveRoleId(string accessToken) returns int|models:AppError {
    map<json>|models:AppError info = userInfo(accessToken);
    if info is models:AppError {
        return info;
    }

    json? claim = info[ROLE_CLAIM];
    int? roleId = ();
    if claim is int {
        roleId = claim;
    } else if claim is decimal {
        roleId = <int>claim;
    } else if claim is float {
        roleId = <int>claim;
    } else if claim is string && claim.trim().length() > 0 {
        int|error parsed = int:fromString(claim.trim());
        if parsed is int {
            roleId = parsed;
        }
    }

    if roleId is () {
        return utils:forbiddenError(
            "Akun Anda belum memiliki role (swaportal_role_id). Hubungi administrator.");
    }
    return roleId;
}

# Loads a role's permission matrix as a `kodeModul -> grant` map, cache-aside from Redis. A cache
# miss (or a Redis outage — logged, not fatal) falls back to the DB and repopulates the key.
#
# + roleId - the role id
# + return - the matrix keyed by modul code, or an error if the DB read failed
function loadRolePermissions(int roleId) returns map<models:RolePermissionItem>|error {
    string cacheKey = "role:" + roleId.toString() + ":permissions";

    json|error cached = repositories:cacheGet(cacheKey);
    if cached is json && cached !is () {
        map<models:RolePermissionItem>|error fromCache = cached.cloneWithType();
        if fromCache is map<models:RolePermissionItem> {
            return fromCache;
        }
        log:printError("role permission cache decode failed, reloading from DB", fromCache);
    } else if cached is error {
        log:printError("role permission cache read failed, falling back to DB", cached);
    }

    models:RolePermissionItem[] items = check repositories:findRolePermissionMatrix(roleId);
    map<models:RolePermissionItem> matrix = {};
    foreach models:RolePermissionItem item in items {
        matrix[item.kodeModul] = item;
    }

    error? cacheErr = repositories:cacheSet(cacheKey, matrix.toJson(),
            ttlSeconds = ROLE_PERMISSION_CACHE_TTL_SECONDS);
    if cacheErr is error {
        log:printError("role permission cache write failed", cacheErr);
    }
    return matrix;
}

# Maps an action verb to the matching permission bit on a modul grant.
#
# + grant - the role's grant row for the target modul
# + action - the action verb (create / read / update / delete / approve / export)
# + return - true if the grant permits the action
function actionAllowed(models:RolePermissionItem grant, string action) returns boolean {
    match action {
        "create" => {
            return grant.canCreate;
        }
        "read" => {
            return grant.canRead;
        }
        "update" => {
            return grant.canUpdate;
        }
        "delete" => {
            return grant.canDelete;
        }
        "approve" => {
            return grant.canApprove;
        }
        "export" => {
            return grant.canExport;
        }
    }
    return false;
}
