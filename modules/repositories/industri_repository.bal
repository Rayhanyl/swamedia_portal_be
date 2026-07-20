import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Industri repository =====
#
# All access to the `industri` table. Queries use parameterized `sql:ParameterizedQuery`
# backtick templates (never string concatenation). Column aliases (`AS "createdAt"`) map
# snake_case DB columns to the camelCase record fields.

# Fetches one page of non-deleted industri rows matching the optional search filter, plus
# the total count of matching rows (for pagination). `search` matches kode OR nama (ILIKE).
#
# + search - optional case-insensitive filter on kode or nama
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findIndustries(string? search, int 'limit, int offset)
        returns record {|models:Industri[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kode ILIKE ${pattern} OR nama ILIKE ${pattern})`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, kode, nama FROM industri WHERE is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Industri[] items = check from models:Industri i in dbc->query(selectQuery, models:Industri)
        select i;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM industri WHERE is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted industri (with audit columns) by id.
#
# + id - the industri id
# + return - the industri, `()` if not found (or already deleted), or an error
public function findIndustriById(int id) returns models:Industri?|error {
    postgresql:Client dbc = check dbClient();
    models:Industri|sql:Error result = dbc->queryRow(`
        SELECT id, kode, nama,
               created_at::text AS "createdAt", updated_at::text AS "updatedAt",
               created_by AS "createdBy", updated_by AS "updatedBy"
        FROM industri WHERE id = ${id} AND is_deleted = false`, models:Industri);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted industri already uses the given kode (case-insensitive).
# `excludeId` skips a specific row (pass 0 on insert; the target id on update).
#
# + kode - the kode to check
# + excludeId - an industri id to exclude from the check (0 = none)
# + return - true if a conflicting kode exists, or an error
public function kodeExists(string kode, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM industri
        WHERE upper(kode) = upper(${kode}) AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether a non-deleted industri with the given id exists (used to validate FK refs
# from other masters, e.g. customer.industri_id).
#
# + id - the industri id to check
# + return - true if an active industri with that id exists, or an error
public function industriExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM industri WHERE id = ${id} AND is_deleted = false`);
    return count > 0;
}

# Returns whether any non-deleted customer or proyek still references this industri
# (blocks soft-delete).
#
# + id - the industri id
# + return - true if at least one active customer/proyek references this industri, or an error
public function isIndustriReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(`
        SELECT EXISTS(SELECT 1 FROM customer WHERE industri_id = ${id} AND is_deleted = false)
            OR EXISTS(SELECT 1 FROM proyek WHERE industri_id = ${id} AND is_deleted = false)`);
    return referenced;
}

# Inserts a new industri and returns the created row (via RETURNING).
#
# + kode - unique industri code (already uppercased/trimmed by the service)
# + nama - industri name
# + createdBy - the `sub` claim of the caller
# + return - the created industri, or an error
public function insertIndustri(string kode, string nama, string createdBy) returns models:Industri|error {
    postgresql:Client dbc = check dbClient();
    models:Industri created = check dbc->queryRow(`
        INSERT INTO industri (kode, nama, created_by)
        VALUES (${kode}, ${nama}, ${createdBy})
        RETURNING id, kode, nama, created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`);
    return created;
}

# Updates a non-deleted industri and returns the updated row (via RETURNING).
#
# + id - the industri id
# + kode - new unique code (already uppercased/trimmed by the service)
# + nama - new name
# + updatedBy - the `sub` claim of the caller
# + return - the updated industri, `()` if the row does not exist (or is deleted), or an error
public function updateIndustri(int id, string kode, string nama, string updatedBy)
        returns models:Industri?|error {
    postgresql:Client dbc = check dbClient();
    models:Industri|sql:Error updated = dbc->queryRow(`
        UPDATE industri SET kode = ${kode}, nama = ${nama}, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id, kode, nama, created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`, models:Industri);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Soft-deletes an industri (sets is_deleted = true). Never physically deletes.
#
# + id - the industri id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteIndustri(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE industri SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
