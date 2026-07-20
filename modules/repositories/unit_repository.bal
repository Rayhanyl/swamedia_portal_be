import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Unit repository =====
#
# All access to the `unit` table. Queries use parameterized `sql:ParameterizedQuery`
# backtick templates (never string concatenation) so every user value is bound safely.
# Column aliases (`AS "namaUnit"`) map snake_case DB columns to the camelCase record fields.

# Fetches one page of non-deleted units matching the optional filters, plus the total
# count of matching rows (for pagination). `search` matches `nama_unit` case-insensitively.
#
# + search - optional ILIKE filter on nama_unit
# + status - optional exact filter on status (AKTIF / TIDAK_AKTIF)
# + parentId - optional filter selecting only children of this unit id
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findUnits(string? search, string? status, int? parentId, int 'limit, int offset)
        returns record {|models:Unit[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND nama_unit ILIKE ${pattern}`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND status = ${status}`);
    }
    if parentId is int {
        conditions.push(` AND parent_unit_id = ${parentId}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT u.id, u.nama_unit AS "namaUnit", u.kode_unit AS "kodeUnit", u.parent_unit_id AS "parentUnitId",
                CASE WHEN EXISTS (SELECT 1 FROM unit c WHERE c.parent_unit_id = u.id AND c.is_deleted = false)
                     THEN 'STRUKTURAL' ELSE 'OPERASIONAL' END AS "tipeUnit",
                u.status
         FROM unit u WHERE u.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Unit[] items = check from models:Unit u in dbc->query(selectQuery, models:Unit)
        select u;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM unit WHERE is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted unit (with audit columns) by id.
#
# + id - the unit id
# + return - the unit, `()` if not found (or already deleted), or an error
public function findUnitById(int id) returns models:Unit?|error {
    postgresql:Client dbc = check dbClient();
    models:Unit|sql:Error result = dbc->queryRow(`
        SELECT u.id, u.nama_unit AS "namaUnit", u.kode_unit AS "kodeUnit", u.parent_unit_id AS "parentUnitId",
               CASE WHEN EXISTS (SELECT 1 FROM unit c WHERE c.parent_unit_id = u.id AND c.is_deleted = false)
                    THEN 'STRUKTURAL' ELSE 'OPERASIONAL' END AS "tipeUnit",
               u.status, u.created_at::text AS "createdAt", u.updated_at::text AS "updatedAt",
               u.created_by AS "createdBy", u.updated_by AS "updatedBy"
        FROM unit u WHERE u.id = ${id} AND u.is_deleted = false`, models:Unit);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Fetches every non-deleted unit (core fields only), ordered by id — the single flat
# read the service layer folds into a tree.
#
# + return - all active units, or an error
public function findAllActiveUnits() returns models:Unit[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:Unit u in dbc->query(`
            SELECT u.id, u.nama_unit AS "namaUnit", u.kode_unit AS "kodeUnit", u.parent_unit_id AS "parentUnitId",
                   CASE WHEN EXISTS (SELECT 1 FROM unit c WHERE c.parent_unit_id = u.id AND c.is_deleted = false)
                        THEN 'STRUKTURAL' ELSE 'OPERASIONAL' END AS "tipeUnit",
                   u.status
            FROM unit u WHERE u.is_deleted = false ORDER BY u.id ASC`, models:Unit)
        select u;
}

# Returns whether a non-deleted unit with the given id exists (used to validate parent refs).
#
# + id - the unit id to check
# + return - true if an active unit with that id exists, or an error
public function unitExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM unit WHERE id = ${id} AND is_deleted = false`);
    return count > 0;
}

# Returns whether another non-deleted unit already uses the given nama_unit. Mirrors the
# friendly-uniqueness-check pattern used by Industri/Tags/Kategori Surat, so a duplicate
# name surfaces as a 409 CONFLICT instead of a raw Postgres unique-violation error.
#
# + namaUnit - the name to check
# + excludeId - a unit id to exclude from the check (0 = none)
# + return - true if a conflicting nama_unit exists, or an error
public function namaUnitExists(string namaUnit, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM unit
        WHERE nama_unit = ${namaUnit} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether another non-deleted unit already uses the given kode_unit (NOT NULL UNIQUE
# in the DB). `excludeId` skips a specific row (pass 0 on insert; the target id on update).
#
# + kodeUnit - the code to check
# + excludeId - a unit id to exclude from the check (0 = none)
# + return - true if a conflicting kode_unit exists, or an error
public function kodeUnitExists(string kodeUnit, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM unit
        WHERE kode_unit = ${kodeUnit} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether the given unit still has any non-deleted child unit (blocks soft-delete).
#
# + id - the parent unit id
# + return - true if at least one active child references this unit, or an error
public function hasActiveChildren(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM unit WHERE parent_unit_id = ${id} AND is_deleted = false`);
    return count > 0;
}

# Inserts a new unit and returns the created row (via RETURNING). `tipeUnit` is hardcoded to
# OPERASIONAL in the RETURNING clause — a brand-new unit can never already have a child.
#
# + namaUnit - unit name
# + kodeUnit - unique unit code (NOT NULL UNIQUE in the DB)
# + parentUnitId - parent unit id, or () for a top-level unit
# + status - AKTIF / TIDAK_AKTIF
# + createdBy - the `sub` claim of the caller
# + return - the created unit, or an error
public function insertUnit(string namaUnit, string kodeUnit, int? parentUnitId, string status, string createdBy)
        returns models:Unit|error {
    postgresql:Client dbc = check dbClient();
    models:Unit created = check dbc->queryRow(`
        INSERT INTO unit (nama_unit, kode_unit, parent_unit_id, status, created_by)
        VALUES (${namaUnit}, ${kodeUnit}, ${parentUnitId}, ${status}, ${createdBy})
        RETURNING id, nama_unit AS "namaUnit", kode_unit AS "kodeUnit", parent_unit_id AS "parentUnitId",
                  'OPERASIONAL' AS "tipeUnit", status,
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`);
    return created;
}

# Updates a non-deleted unit and returns the updated row (via RETURNING).
#
# + id - the unit id
# + namaUnit - new unit name
# + kodeUnit - new unique unit code
# + parentUnitId - new parent unit id, or () to clear it
# + status - new status
# + updatedBy - the `sub` claim of the caller
# + return - the updated unit, `()` if the unit does not exist (or is deleted), or an error
public function updateUnit(int id, string namaUnit, string kodeUnit, int? parentUnitId, string status,
        string updatedBy) returns models:Unit?|error {
    postgresql:Client dbc = check dbClient();
    models:Unit|sql:Error updated = dbc->queryRow(`
        UPDATE unit u SET nama_unit = ${namaUnit}, kode_unit = ${kodeUnit}, parent_unit_id = ${parentUnitId},
               status = ${status}, updated_by = ${updatedBy}, updated_at = now()
        WHERE u.id = ${id} AND u.is_deleted = false
        RETURNING u.id, u.nama_unit AS "namaUnit", u.kode_unit AS "kodeUnit", u.parent_unit_id AS "parentUnitId",
                  CASE WHEN EXISTS (SELECT 1 FROM unit c WHERE c.parent_unit_id = u.id AND c.is_deleted = false)
                       THEN 'STRUKTURAL' ELSE 'OPERASIONAL' END AS "tipeUnit",
                  u.status, u.created_at::text AS "createdAt", u.updated_at::text AS "updatedAt",
                  u.created_by AS "createdBy", u.updated_by AS "updatedBy"`, models:Unit);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Soft-deletes a unit (sets is_deleted = true). Never physically deletes.
#
# + id - the unit id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteUnit(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE unit SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
