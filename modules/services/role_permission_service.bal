import ballerina/log;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== RBAC — Role Permission matrix service =====
#
# `role_permission` has no standalone id-based CRUD from the API's perspective — the "Role &
# Permission" screen edits the whole per-role matrix at once (A14 in the schema), so the
# contract is GET the full matrix (every modul, current grants or defaults) / PUT to replace
# it wholesale. Saving invalidates the `role:{id}:permissions` Redis key the auth middleware
# reads (schema implementation note #7) — cache invalidation is best-effort: a failure is
# logged, never fails the request.

const string ROLE_PERMISSION_SCOPE_ALL = "ALL";
const string ROLE_PERMISSION_SCOPE_UNIT_SENDIRI = "UNIT_SENDIRI";

# Fetches the full permission matrix (every modul row) for a role.
#
# + roleId - the role id
# + return - the role's permission matrix, a NOT_FOUND AppError if the role doesn't exist, or an error
public function getRolePermissions(int roleId) returns models:RolePermissionMatrix|error {
    models:Role? role = check repositories:findRoleById(roleId);
    if role is () {
        return utils:notFoundError("Role dengan id " + roleId.toString() + " tidak ditemukan");
    }

    models:RolePermissionItem[] items = check repositories:findRolePermissionMatrix(roleId);
    return {roleId: role.id, kodeRole: role.kodeRole, namaRole: role.namaRole, items: items};
}

# Replaces the role's entire permission matrix. Every item's modulId must exist in the modul
# master and appear at most once; scope must be ALL or UNIT_SENDIRI.
#
# + roleId - the role id
# + payload - the full set of per-modul grants to persist
# + subject - the caller's `sub` claim, stored as created_by on every row
# + return - the saved matrix, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function replaceRolePermissions(int roleId, models:RolePermissionUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:RolePermissionMatrix|error {
    models:Role? role = check repositories:findRoleById(roleId);
    if role is () {
        return utils:notFoundError("Role dengan id " + roleId.toString() + " tidak ditemukan");
    }

    models:Modul[] modulList = check repositories:findAllModul();
    map<boolean> validModulIds = {};
    foreach models:Modul m in modulList {
        validModulIds[m.id.toString()] = true;
    }

    map<boolean> seenModulIds = {};
    foreach models:RolePermissionUpdateItem item in payload.items {
        string key = item.modulId.toString();
        if !validModulIds.hasKey(key) {
            return utils:validationError("Modul dengan id " + key + " tidak ditemukan");
        }
        if seenModulIds.hasKey(key) {
            return utils:validationError("Modul dengan id " + key + " muncul lebih dari sekali");
        }
        seenModulIds[key] = true;
        if item.scope != ROLE_PERMISSION_SCOPE_ALL && item.scope != ROLE_PERMISSION_SCOPE_UNIT_SENDIRI {
            return utils:validationError("Scope hanya boleh ALL atau UNIT_SENDIRI");
        }
    }

    models:RolePermissionItem[] oldItems = check repositories:findRolePermissionMatrix(roleId);
    check repositories:replaceRolePermissions(roleId, payload.items, subject);

    error? cacheErr = repositories:cacheDelete("role:" + roleId.toString() + ":permissions");
    if cacheErr is error {
        log:printError("Failed to invalidate role permission cache", cacheErr);
    }

    models:RolePermissionItem[] items = check repositories:findRolePermissionMatrix(roleId);
    logAudit("role_permission", roleId.toString(), "UPDATE", oldItems.toJson(), items.toJson(), subject, ipAddress);
    return {roleId: role.id, kodeRole: role.kodeRole, namaRole: role.namaRole, items: items};
}
