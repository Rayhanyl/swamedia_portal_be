import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Unit Share repository =====
#
# All access to the `unit_share` table (how a proyek's value is split across units).
# Parameterized `sql:ParameterizedQuery` templates only. Reads LEFT... actually INNER JOIN `unit`
# to resolve `unitNama` in a single query (no N+1). Every read/mutation is scoped to a proyek_id so
# a share id from one proyek can never be operated on through another proyek's path.

# Lists all non-deleted shares of a proyek (with joined unit name), oldest first.
#
# + proyekId - the owning proyek id
# + return - the shares, or an error
public function findUnitShareByProyek(int proyekId) returns models:UnitShare[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:UnitShare s in dbc->query(`
            SELECT us.id, us.proyek_id AS "proyekId", us.unit_id AS "unitId", u.nama_unit AS "unitNama",
                   us.nilai_share AS "nilaiShare", us.persentase,
                   us.created_at::text AS "createdAt", us.updated_at::text AS "updatedAt",
                   us.created_by AS "createdBy", us.updated_by AS "updatedBy"
            FROM unit_share us
            JOIN unit u ON u.id = us.unit_id
            WHERE us.proyek_id = ${proyekId} AND us.is_deleted = false
            ORDER BY us.id ASC`, models:UnitShare)
        select s;
}

# Fetches a single non-deleted unit_share by id AND owning proyek (with joined unit name + audit).
#
# + id - the unit_share id
# + proyekId - the proyek the share must belong to
# + return - the share, `()` if not found (wrong proyek, missing, or deleted), or an error
public function findUnitShareById(int id, int proyekId) returns models:UnitShare?|error {
    postgresql:Client dbc = check dbClient();
    models:UnitShare|sql:Error result = dbc->queryRow(`
        SELECT us.id, us.proyek_id AS "proyekId", us.unit_id AS "unitId", u.nama_unit AS "unitNama",
               us.nilai_share AS "nilaiShare", us.persentase,
               us.created_at::text AS "createdAt", us.updated_at::text AS "updatedAt",
               us.created_by AS "createdBy", us.updated_by AS "updatedBy"
        FROM unit_share us
        JOIN unit u ON u.id = us.unit_id
        WHERE us.id = ${id} AND us.proyek_id = ${proyekId} AND us.is_deleted = false`, models:UnitShare);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted share already attaches the same unit to the same proyek
# (mirrors the `uq_unit_share_proyek_unit` constraint as a friendly pre-check). `excludeId` skips a
# row (pass 0 on insert; the target id on update).
#
# + proyekId - the proyek id
# + unitId - the unit id
# + excludeId - a share id to exclude (0 = none)
# + return - true if a conflicting (proyek, unit) share exists, or an error
public function unitShareUnitExists(int proyekId, int unitId, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM unit_share
        WHERE proyek_id = ${proyekId} AND unit_id = ${unitId} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Sums the `nilai_share` of a proyek's non-deleted shares, optionally excluding one row — used to
# check the total never exceeds the proyek's `nilai_proyek`. `excludeId` skips a row (pass 0 to sum
# all; the target id on update so the row being replaced isn't double-counted).
#
# + proyekId - the proyek id
# + excludeId - a share id to exclude (0 = none)
# + return - the summed nilai_share (0 when none), or an error
public function sumUnitShare(int proyekId, int excludeId) returns decimal|error {
    postgresql:Client dbc = check dbClient();
    decimal total = check dbc->queryRow(`
        SELECT COALESCE(SUM(nilai_share), 0) FROM unit_share
        WHERE proyek_id = ${proyekId} AND is_deleted = false AND id <> ${excludeId}`);
    return total;
}

# Inserts a new unit_share and returns the created row (joined + audit).
#
# + proyekId - the owning proyek id
# + unitId - the unit receiving the share
# + nilaiShare - absolute value allotted
# + persentase - optional stored percentage
# + createdBy - the `sub` claim of the caller
# + return - the created share, or an error
public function insertUnitShare(int proyekId, int unitId, decimal nilaiShare, decimal? persentase,
        string createdBy) returns models:UnitShare|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO unit_share (proyek_id, unit_id, nilai_share, persentase, created_by)
        VALUES (${proyekId}, ${unitId}, ${nilaiShare}, ${persentase}, ${createdBy})
        RETURNING id`);
    models:UnitShare? created = check findUnitShareById(newId, proyekId);
    if created is () {
        return error("Unit share yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted unit_share (scoped to its proyek) and returns the updated row.
#
# + id - the unit_share id
# + proyekId - the proyek the share must belong to
# + unitId - new unit id
# + nilaiShare - new absolute value allotted
# + persentase - new stored percentage, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - the updated share, `()` if it does not exist (wrong proyek/deleted), or an error
public function updateUnitShare(int id, int proyekId, int unitId, decimal nilaiShare, decimal? persentase,
        string updatedBy) returns models:UnitShare?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE unit_share SET unit_id = ${unitId}, nilai_share = ${nilaiShare}, persentase = ${persentase},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND proyek_id = ${proyekId} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findUnitShareById(id, proyekId);
}

# Soft-deletes a unit_share (sets is_deleted = true). Never physically deletes.
#
# + id - the unit_share id
# + proyekId - the proyek the share must belong to
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (wrong proyek/deleted), or an error
public function softDeleteUnitShare(int id, int proyekId, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE unit_share SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND proyek_id = ${proyekId} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
