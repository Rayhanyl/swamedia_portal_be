import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Audit Log (read-only) service =====
#
# Read-only reporting over the append-only `audit_log` table. Rows are written internally by other
# services (e.g. `nomor_surat_service` on cancel) via `repositories:insertAuditLog` — this module
# never writes, only queries. Date-range filters reuse `validateProyekDate` from `proyek_service`
# (same `services` module) for the YYYY-MM-DD format/parse check.

final string[] AUDIT_LOG_VALID_AKSI = ["CREATE", "UPDATE", "DELETE"];

# Lists audit_log entries with optional filters and pagination, newest first.
#
# + tableName - optional exact table_name filter
# + aksi - optional exact aksi filter (CREATE / UPDATE / DELETE)
# + aktor - optional case-insensitive partial filter on aktor
# + recordId - optional exact record_id filter
# + dateFrom - optional inclusive start date (YYYY-MM-DD)
# + dateTo - optional inclusive end date (YYYY-MM-DD)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, a VALIDATION_ERROR AppError, or an error
public function getAuditLog(string? tableName, string? aksi, string? aktor, string? recordId,
        string? dateFrom, string? dateTo, int page, int 'limit) returns models:AuditLogListResult|error {
    if aksi is string && aksi.trim().length() > 0 && !isValidAksi(aksi) {
        return utils:validationError("Aksi harus CREATE, UPDATE, atau DELETE");
    }
    string? validatedFrom = check validateProyekDate(dateFrom, "Tanggal dari");
    string? validatedTo = check validateProyekDate(dateTo, "Tanggal sampai");
    if validatedFrom is string && validatedTo is string && validatedTo < validatedFrom {
        return utils:validationError("Tanggal sampai tidak boleh sebelum tanggal dari");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:AuditLogEntry[] items; int totalItems;|} result = check repositories:findAuditLog(
            tableName, aksi, aktor, recordId, validatedFrom, validatedTo, safeLimit, offset);

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

# Fetches a single audit_log entry by id.
#
# + id - the audit_log id
# + return - the entry, a NOT_FOUND AppError if it does not exist, or an error
public function getAuditLogById(int id) returns models:AuditLogEntry|error {
    models:AuditLogEntry? entry = check repositories:findAuditLogById(id);
    if entry is () {
        return utils:notFoundError("Audit log dengan id " + id.toString() + " tidak ditemukan");
    }
    return entry;
}

# Validates the aksi filter against the DB's `ck_audit_log_aksi` values.
#
# + aksi - the aksi to check
# + return - true if valid
function isValidAksi(string aksi) returns boolean {
    foreach string a in AUDIT_LOG_VALID_AKSI {
        if a == aksi {
            return true;
        }
    }
    return false;
}
