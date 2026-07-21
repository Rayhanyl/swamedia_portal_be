import ballerina/log;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== RBAC — Role service =====
#
# Business rules and validation for roles. Domain failures are `models:AppError`;
# infrastructure failures propagate as plain `error`. Deleting a role is a hard delete (see
# role_repository) followed by best-effort invalidation of the Redis keys the auth middleware
# reads for this role (`role:{id}:permissions`, `role:{id}:menu` — schema implementation
# note #7): a failed invalidation is logged but never fails the request.

# Lists roles with an optional search/status filter and pagination.
#
# + search - optional case-insensitive filter on kode_role or nama_role
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of roles plus pagination metadata, or an error
public function getRoles(string? search, string? status, int page, int 'limit)
        returns models:RoleListResult|error {
    if status is string && status.trim().length() > 0 && !isValidRoleStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Role[] items; int totalItems;|} result =
        check repositories:findRoles(search, status, safeLimit, offset);

    int totalItems = result.totalItems;
    int totalPages = totalItems == 0 ? 0 : (totalItems + safeLimit - 1) / safeLimit;
    models:Pagination pagination = {
        page: safePage,
        'limit: safeLimit,
        totalItems: totalItems,
        totalPages: totalPages
    };
    return {items: result.items, pagination: pagination};
}

# Fetches a single role by id.
#
# + id - the role id
# + return - the role, or a NOT_FOUND AppError if it does not exist, or an error
public function getRoleById(int id) returns models:Role|error {
    models:Role? role = check repositories:findRoleById(id);
    if role is () {
        return utils:notFoundError("Role dengan id " + id.toString() + " tidak ditemukan");
    }
    return role;
}

# Creates a new role after validating kode/nama/status and kode_role uniqueness.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created role, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createRole(models:RoleCreateRequest payload, string subject) returns models:Role|error {
    string kodeRole = payload.kodeRole.trim();
    check validateKodeRole(kodeRole);
    string namaRole = payload.namaRole.trim();
    check validateNamaRole(namaRole);
    string? deskripsi = normalizeDeskripsi(payload?.deskripsi);

    string status = payload?.status ?: "AKTIF";
    if !isValidRoleStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    boolean duplicate = check repositories:kodeRoleExists(kodeRole, 0);
    if duplicate {
        return utils:conflictError("Kode role sudah digunakan");
    }

    models:Role created = check repositories:insertRole(kodeRole, namaRole, deskripsi, status, subject);
    logAudit("role", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates an existing role. Re-checks kode_role uniqueness excluding the row itself.
#
# + id - the role id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated role, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateRole(int id, models:RoleUpdateRequest payload, string subject) returns models:Role|error {
    string kodeRole = payload.kodeRole.trim();
    check validateKodeRole(kodeRole);
    string namaRole = payload.namaRole.trim();
    check validateNamaRole(namaRole);
    string? deskripsi = normalizeDeskripsi(payload?.deskripsi);

    if !isValidRoleStatus(payload.status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    models:Role? existing = check repositories:findRoleById(id);
    if existing is () {
        return utils:notFoundError("Role dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean duplicate = check repositories:kodeRoleExists(kodeRole, id);
    if duplicate {
        return utils:conflictError("Kode role sudah digunakan");
    }

    models:Role? updated = check repositories:updateRole(id, kodeRole, namaRole, deskripsi, payload.status, subject);
    if updated is () {
        return utils:notFoundError("Role dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("role", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Hard-deletes a role (cascading its role_permission/role_menu rows — see role_repository)
# and invalidates the role's cached permission/menu keys.
#
# + id - the role id to delete
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - (), a NOT_FOUND AppError, or an error
public function deleteRole(int id, string subject) returns error? {
    models:Role? existing = check repositories:findRoleById(id);
    if existing is () {
        return utils:notFoundError("Role dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean deleted = check repositories:deleteRole(id);
    if !deleted {
        return utils:notFoundError("Role dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("role", id.toString(), "DELETE", existing.toJson(), (), subject);

    error? cacheErr = repositories:cacheDelete(
            "role:" + id.toString() + ":permissions", "role:" + id.toString() + ":menu");
    if cacheErr is error {
        log:printError("Failed to invalidate role cache after delete", cacheErr);
    }
    return ();
}

# Validates kode_role: required, maximum 50 characters (after trimming) — matches the DB
# column's VARCHAR(50) NOT NULL UNIQUE constraint.
#
# + kodeRole - the role code to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateKodeRole(string kodeRole) returns models:AppError? {
    if kodeRole.length() < 1 || kodeRole.length() > 50 {
        return utils:validationError("Kode role wajib diisi, panjang maksimal 50 karakter");
    }
    return ();
}

# Validates nama_role: required, maximum 100 characters (after trimming).
#
# + namaRole - the role name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateNamaRole(string namaRole) returns models:AppError? {
    if namaRole.length() < 1 || namaRole.length() > 100 {
        return utils:validationError("Nama role wajib diisi, panjang maksimal 100 karakter");
    }
    return ();
}

# Trims deskripsi and normalizes a blank result to (), matching the nullable DB column.
#
# + deskripsi - the optional raw description
# + return - the trimmed description, or () if nil/blank
function normalizeDeskripsi(string? deskripsi) returns string? {
    if deskripsi is () {
        return ();
    }
    string trimmed = deskripsi.trim();
    return trimmed.length() == 0 ? () : trimmed;
}

function isValidRoleStatus(string status) returns boolean {
    return status == "AKTIF" || status == "TIDAK_AKTIF";
}
