import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Resource Unit repository =====
#
# All access to `resource_unit` (D3) — one row per unit holding headcount / capacity info. JOINs
# `unit` for `unitNama` and LEFT JOINs `karyawan` for the optional lead name (no N+1). Parameterized
# `sql:ParameterizedQuery` templates only. Soft-delete via `is_deleted`; one resource row per unit
# (uq_resource_unit_unit).

# Fetches one page of resource rows matching the optional filters, plus the total count.
#
# + search - optional case-insensitive filter on the unit name
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findResourceUnit(string? search, int? unitId, string? status, int 'limit, int offset)
        returns record {|models:ResourceUnit[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND u.nama_unit ILIKE ${pattern}`);
    }
    if unitId is int {
        conditions.push(` AND ru.unit_id = ${unitId}`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND ru.status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT ru.id, ru.unit_id AS "unitId", u.nama_unit AS "unitNama",
                ru.lead_id AS "leadId", k.nama AS "leadNama",
                ru.jumlah, ru.kapasitas_terpakai AS "kapasitasTerpakai", ru.status
         FROM resource_unit ru
         JOIN unit u ON u.id = ru.unit_id
         LEFT JOIN karyawan k ON k.id = ru.lead_id AND k.is_deleted = false
         WHERE ru.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY u.nama_unit ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:ResourceUnit[] items =
        check from models:ResourceUnit r in dbc->query(selectQuery, models:ResourceUnit)
        select r;

    sql:ParameterizedQuery[] countParts = [
        `SELECT count(*) FROM resource_unit ru JOIN unit u ON u.id = ru.unit_id WHERE ru.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single resource row (with joined unit + lead names + audit) by id.
#
# + id - the resource_unit id
# + return - the row, `()` if not found, or an error
public function findResourceUnitById(int id) returns models:ResourceUnit?|error {
    postgresql:Client dbc = check dbClient();
    models:ResourceUnit|sql:Error result = dbc->queryRow(`
        SELECT ru.id, ru.unit_id AS "unitId", u.nama_unit AS "unitNama",
               ru.lead_id AS "leadId", k.nama AS "leadNama",
               ru.jumlah, ru.kapasitas_terpakai AS "kapasitasTerpakai", ru.status,
               ru.created_at::text AS "createdAt", ru.updated_at::text AS "updatedAt",
               ru.created_by AS "createdBy", ru.updated_by AS "updatedBy"
        FROM resource_unit ru
        JOIN unit u ON u.id = ru.unit_id
        LEFT JOIN karyawan k ON k.id = ru.lead_id AND k.is_deleted = false
        WHERE ru.id = ${id} AND ru.is_deleted = false`, models:ResourceUnit);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether a non-deleted resource row already exists for the given unit (mirrors
# `uq_resource_unit_unit`). `excludeId` skips a row (0 on insert; the resource id on update).
#
# + unitId - the unit id
# + excludeId - a resource_unit id to exclude (0 = none)
# + return - true if a conflicting resource row exists, or an error
public function resourceUnitExistsForUnit(int unitId, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM resource_unit
        WHERE unit_id = ${unitId} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Inserts a new resource row and returns the created row.
#
# + unitId - the unit id
# + leadId - the lead karyawan id, or ()
# + jumlah - headcount
# + kapasitasTerpakai - used-capacity percentage
# + status - AKTIF / TIDAK_AKTIF
# + createdBy - the `sub` claim of the caller
# + return - the created row, or an error
public function insertResourceUnit(int unitId, int? leadId, int jumlah, decimal kapasitasTerpakai,
        string status, string createdBy) returns models:ResourceUnit|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO resource_unit (unit_id, lead_id, jumlah, kapasitas_terpakai, status, created_by)
        VALUES (${unitId}, ${leadId}, ${jumlah}, ${kapasitasTerpakai}, ${status}, ${createdBy})
        RETURNING id`);
    models:ResourceUnit? created = check findResourceUnitById(newId);
    if created is () {
        return error("Resource unit yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a resource row and returns the updated row.
#
# + id - the resource_unit id
# + unitId - new unit id
# + leadId - new lead karyawan id, or ()
# + jumlah - new headcount
# + kapasitasTerpakai - new used-capacity percentage
# + status - new status
# + updatedBy - the `sub` claim of the caller
# + return - the updated row, `()` if it does not exist, or an error
public function updateResourceUnit(int id, int unitId, int? leadId, int jumlah, decimal kapasitasTerpakai,
        string status, string updatedBy) returns models:ResourceUnit?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE resource_unit SET unit_id = ${unitId}, lead_id = ${leadId}, jumlah = ${jumlah},
               kapasitas_terpakai = ${kapasitasTerpakai}, status = ${status},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findResourceUnitById(id);
}

# Soft-deletes a resource row (sets is_deleted = true).
#
# + id - the resource_unit id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was deleted, false if it did not exist, or an error
public function softDeleteResourceUnit(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE resource_unit SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
