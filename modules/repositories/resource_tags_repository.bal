import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Resource Tags repository =====
#
# All access to the `resource_tags` table. Parameterized `sql:ParameterizedQuery` templates only.

# Fetches one page of non-deleted resource tags matching the optional filters, plus the total
# count. `search` matches kode OR nama (ILIKE); `unitId`/`status` filter by exact value.
#
# + search - optional case-insensitive filter on kode or nama
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findResourceTags(string? search, int? unitId, string? status, int 'limit, int offset)
        returns record {|models:ResourceTags[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kode ILIKE ${pattern} OR nama ILIKE ${pattern})`);
    }
    if unitId is int {
        conditions.push(` AND unit_id = ${unitId}`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, kode, nama, unit_id AS "unitId", deskripsi, status FROM resource_tags WHERE is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:ResourceTags[] items = check from models:ResourceTags r in dbc->query(selectQuery, models:ResourceTags)
        select r;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM resource_tags WHERE is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted resource tag (with audit columns) by id.
#
# + id - the resource tag id
# + return - the resource tag, `()` if not found (or already deleted), or an error
public function findResourceTagsById(int id) returns models:ResourceTags?|error {
    postgresql:Client dbc = check dbClient();
    models:ResourceTags|sql:Error result = dbc->queryRow(`
        SELECT id, kode, nama, unit_id AS "unitId", deskripsi, status,
               created_at::text AS "createdAt", updated_at::text AS "updatedAt",
               created_by AS "createdBy", updated_by AS "updatedBy"
        FROM resource_tags WHERE id = ${id} AND is_deleted = false`, models:ResourceTags);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted resource tag already uses the same (kode, unit_id)
# combination. Handles NULL unit_id explicitly (see tags_repository for the rationale).
#
# + kode - the kode to check
# + unitId - the unit_id to check (() = global tag)
# + excludeId - a resource tag id to exclude from the check (0 = none)
# + return - true if a conflicting (kode, unit_id) exists, or an error
public function resourceTagsKodeUnitExists(string kode, int? unitId, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    if unitId is int {
        int count = check dbc->queryRow(`
            SELECT count(*) FROM resource_tags
            WHERE kode = ${kode} AND unit_id = ${unitId} AND is_deleted = false AND id <> ${excludeId}`);
        return count > 0;
    }
    int count = check dbc->queryRow(`
        SELECT count(*) FROM resource_tags
        WHERE kode = ${kode} AND unit_id IS NULL AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether this resource tag is still referenced by a resource_unit (via
# resource_unit_tags) or a tagihan (via tagihan_resource_tags).
#
# + id - the resource tag id
# + return - true if referenced by either junction, or an error
public function isResourceTagReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(`
        SELECT EXISTS(SELECT 1 FROM resource_unit_tags WHERE resource_tags_id = ${id})
            OR EXISTS(SELECT 1 FROM tagihan_resource_tags WHERE resource_tags_id = ${id})`);
    return referenced;
}

# Inserts a new resource tag and returns the created row (via RETURNING).
#
# + kode - resource tag code
# + nama - resource tag name
# + unitId - owning unit id, or () for a global tag
# + deskripsi - optional description
# + status - AKTIF / TIDAK_AKTIF
# + createdBy - the `sub` claim of the caller
# + return - the created resource tag, or an error
public function insertResourceTags(string kode, string nama, int? unitId, string? deskripsi,
        string status, string createdBy) returns models:ResourceTags|error {
    postgresql:Client dbc = check dbClient();
    models:ResourceTags created = check dbc->queryRow(`
        INSERT INTO resource_tags (kode, nama, unit_id, deskripsi, status, created_by)
        VALUES (${kode}, ${nama}, ${unitId}, ${deskripsi}, ${status}, ${createdBy})
        RETURNING id, kode, nama, unit_id AS "unitId", deskripsi, status,
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`);
    return created;
}

# Updates a non-deleted resource tag and returns the updated row (via RETURNING).
#
# + id - the resource tag id
# + kode - new code
# + nama - new name
# + unitId - new owning unit id, or () to clear it
# + deskripsi - new description, or () to clear it
# + status - new status
# + updatedBy - the `sub` claim of the caller
# + return - the updated resource tag, `()` if the row does not exist (or is deleted), or an error
public function updateResourceTags(int id, string kode, string nama, int? unitId, string? deskripsi,
        string status, string updatedBy) returns models:ResourceTags?|error {
    postgresql:Client dbc = check dbClient();
    models:ResourceTags|sql:Error updated = dbc->queryRow(`
        UPDATE resource_tags SET kode = ${kode}, nama = ${nama}, unit_id = ${unitId},
               deskripsi = ${deskripsi}, status = ${status}, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id, kode, nama, unit_id AS "unitId", deskripsi, status,
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`, models:ResourceTags);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Soft-deletes a resource tag (sets is_deleted = true). Never physically deletes.
#
# + id - the resource tag id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteResourceTags(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE resource_tags SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
