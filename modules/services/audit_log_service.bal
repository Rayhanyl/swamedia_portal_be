import ballerina/log;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Audit Log =====
#
# `getAuditLog`/`getAuditLogById` below are read-only reporting over the append-only `audit_log`
# table. `logAudit` is the write side every other create/update/delete service in this module calls
# after its own change has already committed — see its doc for the shape. Date-range filters reuse
# `validateProyekDate` from `proyek_service` (same `services` module) for the YYYY-MM-DD format/parse
# check.

final string[] AUDIT_LOG_VALID_AKSI = ["CREATE", "UPDATE", "DELETE"];

# Best-effort `audit_log` write, called by every other service after its own create/update/delete
# has already committed. Swallows failures (logs them) — a logging hiccup must never fail a request
# whose actual change already succeeded, same treatment this codebase gives other non-critical
# writes (e.g. the Redis cache-aside write in `services:userInfo()`).
#
# `oldData`/`newData` are whole-record JSON snapshots, not per-field diffs — typically `.toJson()` of
# the "before" record a validation step already fetched, and of the "after" record the repository
# call already returned, so callers rarely need to fetch anything extra just for this.
#
# + tableName - the audited table's name (e.g. "unit") — or a logical entity name for changes that
#   land in WSO2 IS rather than a local table (e.g. "user" for Manajemen User/Akun Saya)
# + recordId - the audited row's id — a local table's int PK (as string) or a WSO2 subjectId
# + aksi - "CREATE" / "UPDATE" / "DELETE"
# + oldData - the record's state before the change, or () for CREATE
# + newData - the record's state after the change, or () for DELETE
# + aktor - the caller's `sub` claim (never from the request body)
function logAudit(string tableName, string recordId, string aksi, json? oldData, json? newData, string aktor) {
    json perubahan = {"old": oldData, "new": newData};
    error? auditErr = repositories:insertAuditLog(tableName, recordId, aksi, perubahan, aktor);
    if auditErr is error {
        log:printError("Failed to write audit_log for " + tableName + " " + aksi + " (id=" + recordId + ")",
                auditErr);
    }
}

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
