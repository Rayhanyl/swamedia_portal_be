import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Target Sales Unit repository =====
#
# All access to the `target_sales_unit` table (a unit's per-quarter sales/deal target for a year) —
# the twin of the target_revenue_unit repository, keyed on the same (unit, tahun) uniqueness.
# Parameterized `sql:ParameterizedQuery` templates only. List/detail JOIN `unit` for `unitNama` and
# compute `targetTotal` in a single query. NOTE: this table has no `is_deleted` column — deletes are
# physical.

# Fetches one page of target rows matching the optional filters, plus the total count.
#
# + search - optional case-insensitive filter on the unit name
# + unitId - optional exact unit_id filter
# + tahun - optional exact tahun filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findTargetSalesUnit(string? search, int? unitId, int? tahun, int 'limit, int offset)
        returns record {|models:TargetSalesUnit[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND u.nama_unit ILIKE ${pattern}`);
    }
    if unitId is int {
        conditions.push(` AND ts.unit_id = ${unitId}`);
    }
    if tahun is int {
        conditions.push(` AND ts.tahun = ${tahun}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT ts.id, ts.unit_id AS "unitId", u.nama_unit AS "unitNama", ts.tahun,
                ts.target_tw1 AS "targetTw1", ts.target_tw2 AS "targetTw2",
                ts.target_tw3 AS "targetTw3", ts.target_tw4 AS "targetTw4",
                (ts.target_tw1 + ts.target_tw2 + ts.target_tw3 + ts.target_tw4) AS "targetTotal"
         FROM target_sales_unit ts
         JOIN unit u ON u.id = ts.unit_id
         WHERE 1 = 1`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY ts.tahun DESC, u.nama_unit ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:TargetSalesUnit[] items =
        check from models:TargetSalesUnit t in dbc->query(selectQuery, models:TargetSalesUnit)
        select t;

    sql:ParameterizedQuery[] countParts = [
        `SELECT count(*) FROM target_sales_unit ts JOIN unit u ON u.id = ts.unit_id WHERE 1 = 1`
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
# + id - the target_sales_unit id
# + return - the row, `()` if not found, or an error
public function findTargetSalesUnitById(int id) returns models:TargetSalesUnit?|error {
    postgresql:Client dbc = check dbClient();
    models:TargetSalesUnit|sql:Error result = dbc->queryRow(`
        SELECT ts.id, ts.unit_id AS "unitId", u.nama_unit AS "unitNama", ts.tahun,
               ts.target_tw1 AS "targetTw1", ts.target_tw2 AS "targetTw2",
               ts.target_tw3 AS "targetTw3", ts.target_tw4 AS "targetTw4",
               (ts.target_tw1 + ts.target_tw2 + ts.target_tw3 + ts.target_tw4) AS "targetTotal",
               ts.created_at::text AS "createdAt", ts.updated_at::text AS "updatedAt",
               ts.created_by AS "createdBy", ts.updated_by AS "updatedBy"
        FROM target_sales_unit ts
        JOIN unit u ON u.id = ts.unit_id
        WHERE ts.id = ${id}`, models:TargetSalesUnit);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another row already exists for the same (unit, tahun) — mirrors
# `uq_target_sales_unit_tahun`. `excludeId` skips a row (0 on insert; target id on update).
#
# + unitId - the unit id
# + tahun - the year
# + excludeId - a target id to exclude (0 = none)
# + return - true if a conflicting (unit, tahun) row exists, or an error
public function targetSalesUnitExists(int unitId, int tahun, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM target_sales_unit
        WHERE unit_id = ${unitId} AND tahun = ${tahun} AND id <> ${excludeId}`);
    return count > 0;
}

# Inserts a new target row and returns the created row.
#
# + unitId - the unit id
# + tahun - the year
# + targetTw1 - quarter-1 target
# + targetTw2 - quarter-2 target
# + targetTw3 - quarter-3 target
# + targetTw4 - quarter-4 target
# + createdBy - the `sub` claim of the caller
# + return - the created row, or an error
public function insertTargetSalesUnit(int unitId, int tahun, decimal targetTw1, decimal targetTw2,
        decimal targetTw3, decimal targetTw4, string createdBy) returns models:TargetSalesUnit|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO target_sales_unit (unit_id, tahun, target_tw1, target_tw2, target_tw3, target_tw4,
                created_by)
        VALUES (${unitId}, ${tahun}, ${targetTw1}, ${targetTw2}, ${targetTw3}, ${targetTw4}, ${createdBy})
        RETURNING id`);
    models:TargetSalesUnit? created = check findTargetSalesUnitById(newId);
    if created is () {
        return error("Target sales unit yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a target row and returns the updated row.
#
# + id - the target_sales_unit id
# + unitId - new unit id
# + tahun - new year
# + targetTw1 - new quarter-1 target
# + targetTw2 - new quarter-2 target
# + targetTw3 - new quarter-3 target
# + targetTw4 - new quarter-4 target
# + updatedBy - the `sub` claim of the caller
# + return - the updated row, `()` if it does not exist, or an error
public function updateTargetSalesUnit(int id, int unitId, int tahun, decimal targetTw1, decimal targetTw2,
        decimal targetTw3, decimal targetTw4, string updatedBy) returns models:TargetSalesUnit?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE target_sales_unit SET unit_id = ${unitId}, tahun = ${tahun},
               target_tw1 = ${targetTw1}, target_tw2 = ${targetTw2},
               target_tw3 = ${targetTw3}, target_tw4 = ${targetTw4},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id}`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findTargetSalesUnitById(id);
}

# Physically deletes a target row (this table has no soft-delete column).
#
# + id - the target_sales_unit id
# + return - true if a row was deleted, false if it did not exist, or an error
public function deleteTargetSalesUnit(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`DELETE FROM target_sales_unit WHERE id = ${id}`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
