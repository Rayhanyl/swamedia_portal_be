import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Tags repository =====
#
# All access to the `tags` table. Parameterized `sql:ParameterizedQuery` templates only.

# Fetches one page of non-deleted tags matching the optional filters, plus the total count.
# `search` matches kode OR nama (ILIKE); `unitId` filters by exact unit.
#
# + search - optional case-insensitive filter on kode or nama
# + unitId - optional exact unit_id filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findTags(string? search, int? unitId, int 'limit, int offset)
        returns record {|models:Tags[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kode ILIKE ${pattern} OR nama ILIKE ${pattern})`);
    }
    if unitId is int {
        conditions.push(` AND unit_id = ${unitId}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, kode, nama, unit_id AS "unitId" FROM tags WHERE is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Tags[] items = check from models:Tags t in dbc->query(selectQuery, models:Tags)
        select t;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM tags WHERE is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted tag (with audit columns) by id.
#
# + id - the tag id
# + return - the tag, `()` if not found (or already deleted), or an error
public function findTagsById(int id) returns models:Tags?|error {
    postgresql:Client dbc = check dbClient();
    models:Tags|sql:Error result = dbc->queryRow(`
        SELECT id, kode, nama, unit_id AS "unitId",
               created_at::text AS "createdAt", updated_at::text AS "updatedAt",
               created_by AS "createdBy", updated_by AS "updatedBy"
        FROM tags WHERE id = ${id} AND is_deleted = false`, models:Tags);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted tag already uses the same (kode, unit_id) combination.
# Handles the NULL unit_id case explicitly, since a Postgres UNIQUE constraint treats NULLs
# as distinct — so the friendly duplicate check must be done here. `excludeId` skips a row
# (pass 0 on insert; the target id on update).
#
# + kode - the kode to check
# + unitId - the unit_id to check (() = global tag)
# + excludeId - a tag id to exclude from the check (0 = none)
# + return - true if a conflicting (kode, unit_id) exists, or an error
public function tagsKodeUnitExists(string kode, int? unitId, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    if unitId is int {
        int count = check dbc->queryRow(`
            SELECT count(*) FROM tags
            WHERE kode = ${kode} AND unit_id = ${unitId} AND is_deleted = false AND id <> ${excludeId}`);
        return count > 0;
    }
    int count = check dbc->queryRow(`
        SELECT count(*) FROM tags
        WHERE kode = ${kode} AND unit_id IS NULL AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether any proyek still references this tag (via the proyek_tags junction).
#
# + id - the tag id
# + return - true if referenced, or an error
public function isTagReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM proyek_tags WHERE tags_id = ${id})`);
    return referenced;
}

# Inserts a new tag and returns the created row (via RETURNING).
#
# + kode - tag code
# + nama - tag name
# + unitId - owning unit id, or () for a global tag
# + createdBy - the `sub` claim of the caller
# + return - the created tag, or an error
public function insertTags(string kode, string nama, int? unitId, string createdBy)
        returns models:Tags|error {
    postgresql:Client dbc = check dbClient();
    models:Tags created = check dbc->queryRow(`
        INSERT INTO tags (kode, nama, unit_id, created_by)
        VALUES (${kode}, ${nama}, ${unitId}, ${createdBy})
        RETURNING id, kode, nama, unit_id AS "unitId",
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`);
    return created;
}

# Updates a non-deleted tag and returns the updated row (via RETURNING).
#
# + id - the tag id
# + kode - new tag code
# + nama - new tag name
# + unitId - new owning unit id, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - the updated tag, `()` if the row does not exist (or is deleted), or an error
public function updateTags(int id, string kode, string nama, int? unitId, string updatedBy)
        returns models:Tags?|error {
    postgresql:Client dbc = check dbClient();
    models:Tags|sql:Error updated = dbc->queryRow(`
        UPDATE tags SET kode = ${kode}, nama = ${nama}, unit_id = ${unitId},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id, kode, nama, unit_id AS "unitId",
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`, models:Tags);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Soft-deletes a tag (sets is_deleted = true). Never physically deletes.
#
# + id - the tag id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteTags(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE tags SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
