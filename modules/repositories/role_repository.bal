import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== RBAC — Role repository =====
#
# All access to the `role` table. Unlike most master tables, `role` has no `is_deleted`
# column — a role_permission/role_menu row only makes sense tied to an existing role, so
# `deleteRole` performs a hard delete and cascades the cleanup of both child tables for that
# role_id inside one transaction. Note the schema's own RBAC comment: WSO2 IS only stores a
# `swaportal_role_id` custom attribute reference, never a real FK into this table, so a
# deleted role id cannot dangle a live IS user assignment at the database level.

# Fetches one page of role rows matching the optional search/status filters, plus the total
# matching count. `search` matches kode_role OR nama_role (ILIKE).
#
# + search - optional case-insensitive filter on kode_role or nama_role
# + status - optional exact filter on status (AKTIF / TIDAK_AKTIF)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findRoles(string? search, string? status, int 'limit, int offset)
        returns record {|models:Role[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kode_role ILIKE ${pattern} OR nama_role ILIKE ${pattern})`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, kode_role AS "kodeRole", nama_role AS "namaRole", deskripsi, status
         FROM role WHERE 1=1`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Role[] items = check from models:Role r in dbc->query(selectQuery, models:Role)
        select r;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM role WHERE 1=1`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single role (with audit columns) by id.
#
# + id - the role id
# + return - the role, `()` if not found, or an error
public function findRoleById(int id) returns models:Role?|error {
    postgresql:Client dbc = check dbClient();
    models:Role|sql:Error result = dbc->queryRow(`
        SELECT id, kode_role AS "kodeRole", nama_role AS "namaRole", deskripsi, status,
               created_at::text AS "createdAt", updated_at::text AS "updatedAt",
               created_by AS "createdBy", updated_by AS "updatedBy"
        FROM role WHERE id = ${id}`, models:Role);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether a role with the given id exists (used to validate role_id in the
# role_permission/role_menu matrix endpoints).
#
# + id - the role id to check
# + return - true if a role with that id exists, or an error
public function roleExists(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM role WHERE id = ${id}`);
    return count > 0;
}

# Returns whether another role already uses the given kode_role (NOT NULL UNIQUE in the DB).
# `excludeId` skips a specific row (pass 0 on insert; the target id on update).
#
# + kodeRole - the code to check
# + excludeId - a role id to exclude from the check (0 = none)
# + return - true if a conflicting kode_role exists, or an error
public function kodeRoleExists(string kodeRole, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM role WHERE kode_role = ${kodeRole} AND id <> ${excludeId}`);
    return count > 0;
}

# Inserts a new role and returns the created row (via RETURNING).
#
# + kodeRole - unique role code
# + namaRole - role name
# + deskripsi - optional description
# + status - AKTIF / TIDAK_AKTIF
# + createdBy - the `sub` claim of the caller
# + return - the created role, or an error
public function insertRole(string kodeRole, string namaRole, string? deskripsi, string status, string createdBy)
        returns models:Role|error {
    postgresql:Client dbc = check dbClient();
    models:Role created = check dbc->queryRow(`
        INSERT INTO role (kode_role, nama_role, deskripsi, status, created_by)
        VALUES (${kodeRole}, ${namaRole}, ${deskripsi}, ${status}, ${createdBy})
        RETURNING id, kode_role AS "kodeRole", nama_role AS "namaRole", deskripsi, status,
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`);
    return created;
}

# Updates a role and returns the updated row (via RETURNING).
#
# + id - the role id
# + kodeRole - new unique role code
# + namaRole - new role name
# + deskripsi - new description, or () to clear it
# + status - new status
# + updatedBy - the `sub` claim of the caller
# + return - the updated role, `()` if the role does not exist, or an error
public function updateRole(int id, string kodeRole, string namaRole, string? deskripsi, string status,
        string updatedBy) returns models:Role?|error {
    postgresql:Client dbc = check dbClient();
    models:Role|sql:Error updated = dbc->queryRow(`
        UPDATE role SET kode_role = ${kodeRole}, nama_role = ${namaRole}, deskripsi = ${deskripsi},
               status = ${status}, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id}
        RETURNING id, kode_role AS "kodeRole", nama_role AS "namaRole", deskripsi, status,
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`, models:Role);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Hard-deletes a role after clearing its role_permission and role_menu rows, inside a single
# transaction (both child tables reference role_id with no ON DELETE CASCADE, so deleting the
# role first would fail on the FK constraint).
#
# + id - the role id
# + return - true if the role row was deleted, false if it did not exist, or an error
public function deleteRole(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean deleted = false;
    transaction {
        _ = check dbc->execute(`DELETE FROM role_permission WHERE role_id = ${id}`);
        _ = check dbc->execute(`DELETE FROM role_menu WHERE role_id = ${id}`);
        sql:ExecutionResult result = check dbc->execute(`DELETE FROM role WHERE id = ${id}`);
        int? affected = result.affectedRowCount;
        deleted = affected is int && affected > 0;
        check commit;
    }
    return deleted;
}
