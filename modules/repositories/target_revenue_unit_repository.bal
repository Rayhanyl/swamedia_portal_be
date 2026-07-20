import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Target Revenue Unit repository =====
#
# All access to the `target_revenue_unit` table (a unit's per-quarter revenue target for a year).
# Parameterized `sql:ParameterizedQuery` templates only. List/detail JOIN `unit` to resolve
# `unitNama` and compute `targetTotal` (sum of the four quarters) in a single query (no N+1). NOTE:
# this table has no `is_deleted` column — deletes are physical.

# Fetches one page of target rows matching the optional filters, plus the total count. `search`
# matches the joined unit name (ILIKE).
#
# + search - optional case-insensitive filter on the unit name
# + unitId - optional exact unit_id filter
# + tahun - optional exact tahun filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findTargetRevenueUnit(string? search, int? unitId, int? tahun, int 'limit, int offset)
        returns record {|models:TargetRevenueUnit[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND u.nama_unit ILIKE ${pattern}`);
    }
    if unitId is int {
        conditions.push(` AND tr.unit_id = ${unitId}`);
    }
    if tahun is int {
        conditions.push(` AND tr.tahun = ${tahun}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT tr.id, tr.unit_id AS "unitId", u.nama_unit AS "unitNama", tr.tahun,
                tr.target_tw1 AS "targetTw1", tr.target_tw2 AS "targetTw2",
                tr.target_tw3 AS "targetTw3", tr.target_tw4 AS "targetTw4",
                (tr.target_tw1 + tr.target_tw2 + tr.target_tw3 + tr.target_tw4) AS "targetTotal"
         FROM target_revenue_unit tr
         JOIN unit u ON u.id = tr.unit_id
         WHERE 1 = 1`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY tr.tahun DESC, u.nama_unit ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:TargetRevenueUnit[] items =
        check from models:TargetRevenueUnit t in dbc->query(selectQuery, models:TargetRevenueUnit)
        select t;

    sql:ParameterizedQuery[] countParts = [
        `SELECT count(*) FROM target_revenue_unit tr JOIN unit u ON u.id = tr.unit_id WHERE 1 = 1`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single target row (with joined unit name + computed total + audit) by id.
#
# + id - the target_revenue_unit id
# + return - the row, `()` if not found, or an error
public function findTargetRevenueUnitById(int id) returns models:TargetRevenueUnit?|error {
    postgresql:Client dbc = check dbClient();
    models:TargetRevenueUnit|sql:Error result = dbc->queryRow(`
        SELECT tr.id, tr.unit_id AS "unitId", u.nama_unit AS "unitNama", tr.tahun,
               tr.target_tw1 AS "targetTw1", tr.target_tw2 AS "targetTw2",
               tr.target_tw3 AS "targetTw3", tr.target_tw4 AS "targetTw4",
               (tr.target_tw1 + tr.target_tw2 + tr.target_tw3 + tr.target_tw4) AS "targetTotal",
               tr.created_at::text AS "createdAt", tr.updated_at::text AS "updatedAt",
               tr.created_by AS "createdBy", tr.updated_by AS "updatedBy"
        FROM target_revenue_unit tr
        JOIN unit u ON u.id = tr.unit_id
        WHERE tr.id = ${id}`, models:TargetRevenueUnit);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another row already exists for the same (unit, tahun) — mirrors
# `uq_target_revenue_unit_tahun` as a friendly pre-check. `excludeId` skips a row (0 on insert;
# target id on update).
#
# + unitId - the unit id
# + tahun - the year
# + excludeId - a target id to exclude (0 = none)
# + return - true if a conflicting (unit, tahun) row exists, or an error
public function targetRevenueUnitExists(int unitId, int tahun, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM target_revenue_unit
        WHERE unit_id = ${unitId} AND tahun = ${tahun} AND id <> ${excludeId}`);
    return count > 0;
}

# Inserts a new target row and returns the created row (assembled).
#
# + unitId - the unit id
# + tahun - the year
# + targetTw1 - quarter-1 target
# + targetTw2 - quarter-2 target
# + targetTw3 - quarter-3 target
# + targetTw4 - quarter-4 target
# + createdBy - the `sub` claim of the caller
# + return - the created row, or an error
public function insertTargetRevenueUnit(int unitId, int tahun, decimal targetTw1, decimal targetTw2,
        decimal targetTw3, decimal targetTw4, string createdBy) returns models:TargetRevenueUnit|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO target_revenue_unit (unit_id, tahun, target_tw1, target_tw2, target_tw3, target_tw4,
                created_by)
        VALUES (${unitId}, ${tahun}, ${targetTw1}, ${targetTw2}, ${targetTw3}, ${targetTw4}, ${createdBy})
        RETURNING id`);
    models:TargetRevenueUnit? created = check findTargetRevenueUnitById(newId);
    if created is () {
        return error("Target revenue unit yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a target row and returns the updated row.
#
# + id - the target_revenue_unit id
# + unitId - new unit id
# + tahun - new year
# + targetTw1 - new quarter-1 target
# + targetTw2 - new quarter-2 target
# + targetTw3 - new quarter-3 target
# + targetTw4 - new quarter-4 target
# + updatedBy - the `sub` claim of the caller
# + return - the updated row, `()` if it does not exist, or an error
public function updateTargetRevenueUnit(int id, int unitId, int tahun, decimal targetTw1, decimal targetTw2,
        decimal targetTw3, decimal targetTw4, string updatedBy) returns models:TargetRevenueUnit?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE target_revenue_unit SET unit_id = ${unitId}, tahun = ${tahun},
               target_tw1 = ${targetTw1}, target_tw2 = ${targetTw2},
               target_tw3 = ${targetTw3}, target_tw4 = ${targetTw4},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id}`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findTargetRevenueUnitById(id);
}

# Physically deletes a target row (this table has no soft-delete column).
#
# + id - the target_revenue_unit id
# + return - true if a row was deleted, false if it did not exist, or an error
public function deleteTargetRevenueUnit(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`DELETE FROM target_revenue_unit WHERE id = ${id}`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
