import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Notifikasi repository =====
#
# All access to the `notification` table. Parameterized `sql:ParameterizedQuery` templates only.
# Every query is scoped to a `recipient_karyawan_id` (the caller's own karyawan id, resolved
# server-side by the service layer) so one user's notifications can never be listed, counted, or
# marked read by another. This table has no `is_deleted` column and no `created_by`/`updated_by` —
# notifications are written by other business flows (a future concern), not authored by end users,
# so this module is read/acknowledge-only from the API's perspective.

# Fetches one page of a recipient's notifications matching the optional filters, plus the total
# count, newest first.
#
# + recipientKaryawanId - the recipient's karyawan id
# + kategori - optional exact kategori filter (PENUGASAN / STATUS / SISTEM)
# + isRead - optional exact is_read filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findNotificationByRecipient(int recipientKaryawanId, string? kategori, boolean? isRead,
        int 'limit, int offset) returns record {|models:Notification[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if kategori is string && kategori.trim().length() > 0 {
        conditions.push(` AND kategori = ${kategori}`);
    }
    if isRead is boolean {
        conditions.push(` AND is_read = ${isRead}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, kategori, judul, pesan, ref_table AS "refTable", ref_id AS "refId",
                link_label AS "linkLabel", is_read AS "isRead", read_at::text AS "readAt",
                created_at::text AS "createdAt"
         FROM notification WHERE recipient_karyawan_id = ${recipientKaryawanId}`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY created_at DESC, id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Notification[] items =
        check from models:Notification n in dbc->query(selectQuery, models:Notification)
        select n;

    sql:ParameterizedQuery[] countParts = [
        `SELECT count(*) FROM notification WHERE recipient_karyawan_id = ${recipientKaryawanId}`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Counts a recipient's unread notifications (for a badge count).
#
# + recipientKaryawanId - the recipient's karyawan id
# + return - the unread count, or an error
public function countUnreadNotification(int recipientKaryawanId) returns int|error {
    postgresql:Client dbc = check dbClient();
    return check dbc->queryRow(
        `SELECT count(*) FROM notification WHERE recipient_karyawan_id = ${recipientKaryawanId} AND is_read = false`);
}

# Marks a single notification as read, scoped to its recipient — an id belonging to a different
# karyawan matches zero rows (reported as NOT_FOUND by the service, never leaked cross-user).
# Idempotent: marking an already-read notification again still returns true.
#
# + id - the notification id
# + recipientKaryawanId - the recipient's karyawan id (ownership check)
# + return - true if the notification exists (and now is_read), false if not found, or an error
public function markNotificationRead(int id, int recipientKaryawanId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE notification SET is_read = true, read_at = COALESCE(read_at, now())
        WHERE id = ${id} AND recipient_karyawan_id = ${recipientKaryawanId}`);
    int? affected = result.affectedRowCount;
    if affected is int && affected > 0 {
        return true;
    }
    // affectedRowCount is 0 both when the row doesn't exist AND when it was already read (no
    // columns changed) — disambiguate with an existence check so "already read" isn't reported
    // as NOT_FOUND.
    boolean exists = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM notification WHERE id = ${id} AND recipient_karyawan_id = ${recipientKaryawanId})`);
    return exists;
}

# Marks all of a recipient's unread notifications as read.
#
# + recipientKaryawanId - the recipient's karyawan id
# + return - the number of notifications marked read, or an error
public function markAllNotificationRead(int recipientKaryawanId) returns int|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE notification SET is_read = true, read_at = now()
        WHERE recipient_karyawan_id = ${recipientKaryawanId} AND is_read = false`);
    int? affected = result.affectedRowCount;
    return affected ?: 0;
}
