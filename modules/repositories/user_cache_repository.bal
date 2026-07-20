import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Manajemen User — user_cache repository =====
#
# Read access to the `user_cache` table (the local mirror of WSO2 IS users), LEFT JOINed to
# `karyawan` on `subject_id` to surface the linked karyawan (if any) in a single query (no N+1).
# The authoritative user store is WSO2 IS (written via SCIM2 — see scim2_repository.bal); the only
# write here is `upsertUserCache`, a WRITE-THROUGH that mirrors a just-succeeded SCIM2 change into
# this cache so the read side reflects it immediately without waiting for the reconciliation job.

# Fetches one page of user_cache rows matching the optional filters, plus the total count,
# ordered by nama (unsynced rows with a null nama sort last).
#
# + search - optional case-insensitive filter on subject_id, nama, or email
# + status - optional exact status filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findUserCache(string? search, string? status, int 'limit, int offset)
        returns record {|models:UserCacheItem[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(
            ` AND (uc.subject_id ILIKE ${pattern} OR uc.nama ILIKE ${pattern} OR uc.email ILIKE ${pattern})`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND uc.status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT uc.subject_id AS "subjectId", uc.nama, uc.email, uc.status,
                uc.sync_source AS "syncSource", uc.last_synced_at::text AS "lastSyncedAt",
                k.id AS "karyawanId", k.nama AS "karyawanNama"
         FROM user_cache uc
         LEFT JOIN karyawan k ON k.subject_id = uc.subject_id AND k.is_deleted = false
         WHERE 1 = 1`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY uc.nama ASC NULLS LAST, uc.subject_id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:UserCacheItem[] items =
        check from models:UserCacheItem u in dbc->query(selectQuery, models:UserCacheItem)
        select u;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM user_cache uc WHERE 1 = 1`];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single user_cache row (with linked karyawan, if any) by subject_id.
#
# + subjectId - the WSO2 IS subject id
# + return - the row, `()` if not found, or an error
public function findUserCacheBySubjectId(string subjectId) returns models:UserCacheItem?|error {
    postgresql:Client dbc = check dbClient();
    models:UserCacheItem|sql:Error result = dbc->queryRow(`
        SELECT uc.subject_id AS "subjectId", uc.nama, uc.email, uc.status,
               uc.sync_source AS "syncSource", uc.last_synced_at::text AS "lastSyncedAt",
               k.id AS "karyawanId", k.nama AS "karyawanNama"
        FROM user_cache uc
        LEFT JOIN karyawan k ON k.subject_id = uc.subject_id AND k.is_deleted = false
        WHERE uc.subject_id = ${subjectId}`, models:UserCacheItem);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Write-through upsert of a WSO2 IS user into `user_cache` after a successful SCIM2 write, keyed on
# subject_id. Sets sync_source = 'WSO2_IS' and last_synced_at = now(). A nil `status` leaves any
# existing status untouched (used by the profile update, which doesn't change status).
#
# + subjectId - the WSO2 IS subject id (SCIM user id)
# + nama - the user's display name
# + email - the user's email
# + status - the account status to store, or () to keep the existing one
# + return - an error if the write failed
public function upsertUserCache(string subjectId, string nama, string email, string? status) returns error? {
    postgresql:Client dbc = check dbClient();
    _ = check dbc->execute(`
        INSERT INTO user_cache (subject_id, nama, email, status, sync_source, last_synced_at)
        VALUES (${subjectId}, ${nama}, ${email}, ${status}, 'WSO2_IS', now())
        ON CONFLICT (subject_id) DO UPDATE
        SET nama = EXCLUDED.nama, email = EXCLUDED.email,
            status = COALESCE(EXCLUDED.status, user_cache.status),
            sync_source = 'WSO2_IS', last_synced_at = now()`);
}

# Write-through of an account status change (enable/disable) into `user_cache`.
#
# + subjectId - the WSO2 IS subject id
# + status - the new status string
# + return - an error if the write failed
public function updateUserCacheStatus(string subjectId, string status) returns error? {
    postgresql:Client dbc = check dbClient();
    _ = check dbc->execute(`
        UPDATE user_cache SET status = ${status}, sync_source = 'WSO2_IS', last_synced_at = now()
        WHERE subject_id = ${subjectId}`);
}
