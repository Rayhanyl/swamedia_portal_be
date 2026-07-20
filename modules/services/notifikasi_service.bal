import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Notifikasi (self-service notification inbox) service =====
#
# Every operation resolves the caller's own karyawan id via `requireKaryawanBySubject` (reused from
# `profil_saya_service`, same `services` module) and every read/mutation is scoped to that
# recipient_karyawan_id — a notification id belonging to a different karyawan is reported as
# NOT_FOUND, never leaked or mutated cross-user. This module is read/acknowledge only: notifications
# themselves are written by other business flows (a future concern), not created via this API.

final string[] NOTIFICATION_VALID_KATEGORI = ["PENUGASAN", "STATUS", "SISTEM"];

# Lists the caller's own notifications with optional filters and pagination.
#
# + subject - the caller's `sub` claim
# + kategori - optional exact kategori filter (PENUGASAN / STATUS / SISTEM)
# + isRead - optional exact is_read filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function getNotifikasi(string subject, string? kategori, boolean? isRead, int page, int 'limit)
        returns models:NotificationListResult|error {
    models:KaryawanDetail karyawan = check requireKaryawanBySubject(subject);
    if kategori is string && kategori.trim().length() > 0 && !isValidKategori(kategori) {
        return utils:validationError("Kategori harus PENUGASAN, STATUS, atau SISTEM");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Notification[] items; int totalItems;|} result =
        check repositories:findNotificationByRecipient(karyawan.id, kategori, isRead, safeLimit, offset);

    int totalItems = result.totalItems;
    int totalPages = totalItems == 0 ? 0 : (totalItems + safeLimit - 1) / safeLimit;
    models:Pagination pagination = {
        page: safePage,
        'limit: safeLimit,
        totalItems: totalItems,
        totalPages: totalPages
    };
    return {items: result.items, pagination: pagination};
}

# Returns the caller's unread notification count (for a badge).
#
# + subject - the caller's `sub` claim
# + return - the unread count, a NOT_FOUND AppError if no karyawan is linked, or an error
public function getNotifikasiUnreadCount(string subject) returns models:NotificationUnreadCount|error {
    models:KaryawanDetail karyawan = check requireKaryawanBySubject(subject);
    int count = check repositories:countUnreadNotification(karyawan.id);
    return {unreadCount: count};
}

# Marks one of the caller's own notifications as read.
#
# + subject - the caller's `sub` claim
# + id - the notification id
# + return - (), a NOT_FOUND AppError (missing, or belongs to someone else), or an error
public function markNotifikasiRead(string subject, int id) returns error? {
    models:KaryawanDetail karyawan = check requireKaryawanBySubject(subject);
    boolean updated = check repositories:markNotificationRead(id, karyawan.id);
    if !updated {
        return utils:notFoundError("Notifikasi dengan id " + id.toString() + " tidak ditemukan");
    }
    return ();
}

# Marks all of the caller's unread notifications as read.
#
# + subject - the caller's `sub` claim
# + return - (), a NOT_FOUND AppError if no karyawan is linked, or an error
public function markAllNotifikasiRead(string subject) returns error? {
    models:KaryawanDetail karyawan = check requireKaryawanBySubject(subject);
    _ = check repositories:markAllNotificationRead(karyawan.id);
    return ();
}

# Validates the kategori filter against the DB's `ck_notification_kategori` values.
#
# + kategori - the kategori to check
# + return - true if valid
function isValidKategori(string kategori) returns boolean {
    foreach string k in NOTIFICATION_VALID_KATEGORI {
        if k == kategori {
            return true;
        }
    }
    return false;
}
