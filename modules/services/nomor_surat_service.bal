import ballerina/lang.regexp;
import ballerina/log;
import ballerina/time;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== e-Office — Daftar Surat (nomor_surat) service =====
#
# Business rules for the letter register ("Daftar Surat" in the UI; nomor_surat in the schema).
# Domain failures are `models:AppError`; infrastructure failures propagate as plain `error`.
#
# The critical logic here is automatic number generation. A number is
# {prefix}-{kode_kategori}-{tahun}-{urutan zero-padded to 3 digits}, e.g. "SK-DR-02-2026-012".
# The read-MAX-then-insert step is done atomically in the repository transaction; this service
# validates inputs, resolves the prefix + kategori code, and maps a race-condition constraint
# violation to a friendly CONFLICT 409 rather than a generic 500.

# tanggal must look like YYYY-MM-DD before we attempt to parse it.
final regexp:RegExp DATE_PATTERN = re `[0-9]{4}-[0-9]{2}-[0-9]{2}`;

# Lists letters with optional filters and pagination. `tahun` defaults to the current year when
# the caller omits it (the UI's default "this year" view). By default only active (non-cancelled)
# letters are returned; `includeDibatalkan` additionally surfaces cancelled ones for audit/report
# views (each row's `isDibatalkan`/`alasanPembatalan` lets the caller tell them apart).
#
# + search - optional case-insensitive filter on nomor/tujuan/perihal
# + tahun - optional numbering-year filter (defaults to the current year)
# + kategoriSuratId - optional exact kategori_surat_id filter
# + proyekId - optional exact proyek_id filter
# + includeDibatalkan - when true, also includes cancelled letters
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of letters plus pagination metadata, or an error
public function getNomorSuratList(string? search, int? tahun, int? kategoriSuratId, int? proyekId,
        boolean includeDibatalkan, int page, int 'limit) returns models:NomorSuratListResult|error {
    int effectiveTahun = tahun ?: currentYear();

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:NomorSurat[] items; int totalItems;|} result = check repositories:findNomorSurat(
            search, effectiveTahun, kategoriSuratId, proyekId, includeDibatalkan, safeLimit, offset);

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

# Fetches a single letter (with joined display names) by id.
#
# + id - the nomor_surat id
# + return - the letter detail, or a NOT_FOUND AppError if it does not exist, or an error
public function getNomorSuratById(int id) returns models:NomorSurat|error {
    models:NomorSurat? surat = check repositories:findNomorSuratById(id);
    if surat is () {
        return utils:notFoundError("Surat dengan id " + id.toString() + " tidak ditemukan");
    }
    return surat;
}

# Computes the number a create would produce RIGHT NOW, without reserving anything — a pure read
# (SELECT MAX(urutan)+1), no transaction, no lock, no insert. Calling it twice for the same
# (kategori, tahun) with no create in between yields the same value; if another request commits a
# create first, the value simply advances. That non-reservation is intentional — the actual
# collision-safe allocation happens in createNomorSurat's transaction, not here.
#
# + kategoriSuratId - the selected kategori_surat id (required; nil -> VALIDATION_ERROR)
# + tanggal - the letter date YYYY-MM-DD (required; nil/blank -> VALIDATION_ERROR)
# + return - the previewed nomor, a VALIDATION_ERROR AppError, or an error
public function previewNomor(int? kategoriSuratId, string? tanggal) returns models:NomorSuratPreview|error {
    if kategoriSuratId is () || tanggal is () || tanggal.trim().length() == 0 {
        return utils:validationError("kategori_surat_id dan tanggal wajib diisi untuk preview nomor");
    }
    string tgl = tanggal.trim();
    check validateTanggal(tgl);

    NomorGenContext ctx = check resolveNomorContext(kategoriSuratId, tgl);
    int urutan = check repositories:getNextUrutan(kategoriSuratId, ctx.tahun);
    return {nomorPreview: repositories:formatNomor(ctx.prefix, ctx.kodeKategori, ctx.tahun, urutan)};
}

# Creates a new letter: validates inputs and the kategori/proyek references, resolves the prefix
# and kategori code, then delegates the atomic number-generate + insert to the repository. Returns
# the freshly joined detail.
#
# + payload - the create request body (nomor/tahun/urutan are computed here, never taken from it)
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created letter detail, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createNomorSurat(models:NomorSuratCreateRequest payload, string subject)
        returns models:NomorSurat|error {
    string tanggal = payload.tanggal.trim();
    check validateTanggal(tanggal);

    string tujuan = payload.tujuan.trim();
    check validateTujuan(tujuan);
    string perihal = payload.perihal.trim();
    check validatePerihal(perihal);
    string? keterangan = trimToNil(payload?.keterangan);

    int? proyekId = payload?.proyekId;
    check validateProyek(proyekId);

    // Resolve the shared front half of the number (prefix + kode kategori + tahun); this also
    // validates that the kategori exists. The urutan and final string are formed atomically in
    // the repository transaction.
    NomorGenContext ctx = check resolveNomorContext(payload.kategoriSuratId, tanggal);

    int|error inserted = repositories:insertNomorSurat(payload.kategoriSuratId, ctx.prefix, ctx.kodeKategori,
            proyekId, tanggal, ctx.tahun, tujuan, perihal, keterangan, subject);
    if inserted is error {
        // Two expected (not buggy) outcomes of concurrent creates for the same (kategori, tahun):
        // (1) the advisory lock's `lock_timeout` was exceeded (a peer transaction held it too
        //     long — e.g. a deadlock elsewhere), or
        // (2) the unique constraint still fired as a last-resort safety net.
        // Either way this is a "try again" situation, not a server bug, so surface it as CONFLICT.
        if isLockTimeout(inserted) || isUniqueViolation(inserted) {
            return utils:conflictError("Nomor surat sedang diproses oleh request lain, silakan coba lagi");
        }
        return inserted;
    }

    models:NomorSurat? created = check repositories:findNomorSuratById(inserted);
    if created is () {
        return error("Nomor surat created (id " + inserted.toString() + ") but could not be read back");
    }
    logAudit("nomor_surat", inserted.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates a letter's mutable fields (tanggal/proyekId/tujuan/perihal/keterangan). The immutable
# fields (kategori_surat_id, tahun, urutan, nomor) are never changed — even when the new tanggal
# falls in a different year, the stored tahun and the generated nomor stay as first issued.
#
# + id - the nomor_surat id to update
# + payload - the update request body (immutable fields, if sent, are ignored via the open record)
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated letter detail, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updateNomorSurat(int id, models:NomorSuratUpdateRequest payload, string subject)
        returns models:NomorSurat|error {
    string tanggal = payload.tanggal.trim();
    check validateTanggal(tanggal);
    string tujuan = payload.tujuan.trim();
    check validateTujuan(tujuan);
    string perihal = payload.perihal.trim();
    check validatePerihal(perihal);
    string? keterangan = trimToNil(payload?.keterangan);

    int? proyekId = payload?.proyekId;
    check validateProyek(proyekId);

    models:NomorSurat? existing = check repositories:findNomorSuratById(id);
    if existing is () {
        return utils:notFoundError("Surat dengan id " + id.toString() + " tidak ditemukan");
    }

    int? updatedId = check repositories:updateNomorSurat(id, tanggal, proyekId, tujuan, perihal, keterangan, subject);
    if updatedId is () {
        return utils:notFoundError("Surat dengan id " + id.toString() + " tidak ditemukan");
    }

    models:NomorSurat? updated = check repositories:findNomorSuratById(id);
    if updated is () {
        return utils:notFoundError("Surat dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("nomor_surat", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Minimum length for `alasanPembatalan`, enforced after trimming — rejects lazy filler like "-" or "x".
const int ALASAN_PEMBATALAN_MIN_LENGTH = 5;

# Cancels a letter: a soft-delete that WAJIB records a reason for the audit trail. This is not an
# auto-copy/duplicate flow — if the user needs a replacement letter, they create one from scratch
# via a normal POST. Cancelling an already-cancelled (or non-existent) letter is rejected as
# NOT_FOUND rather than silently succeeding again, since that would signal a duplicate request or a
# frontend bug.
#
# + id - the nomor_surat id to cancel
# + payload - the cancellation request body (alasanPembatalan is mandatory)
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the cancelled letter's id/nomor/alasanPembatalan, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function cancelNomorSurat(int id, models:CancelNomorSuratRequest payload, string subject)
        returns models:NomorSuratCancelled|error {
    string alasan = payload.alasanPembatalan.trim();
    if alasan.length() == 0 {
        return utils:validationError("Alasan pembatalan wajib diisi");
    }
    if alasan.length() < ALASAN_PEMBATALAN_MIN_LENGTH {
        return utils:validationError("Alasan pembatalan minimal 5 karakter");
    }

    // findNomorSuratById only filters is_deleted = false (the standard soft-delete flag) — an
    // already-cancelled letter still has is_deleted = false, so it IS found here (needed so its
    // nomor/id are available below for a clean error, and so the detail endpoint can still show
    // cancelled letters). The "already cancelled" case is instead caught by the explicit
    // isDibatalkan check right below, and as a second line of defense, `cancelNomorSurat`'s own
    // `WHERE ... AND is_dibatalkan = false` guard (covers the race where another request cancels
    // it between this read and the update).
    models:NomorSurat? existing = check repositories:findNomorSuratById(id);
    if existing is () || existing.isDibatalkan {
        return utils:notFoundError("Surat tidak ditemukan atau sudah dibatalkan sebelumnya");
    }

    boolean cancelled = check repositories:cancelNomorSurat(id, alasan, subject);
    if !cancelled {
        // Rare race: cancelled by another request between the read above and this update.
        return utils:notFoundError("Surat tidak ditemukan atau sudah dibatalkan sebelumnya");
    }

    // Audit trail for the cancellation, recorded as DELETE since a cancelled letter is retired
    // rather than edited. Goes through the shared `logAudit` (audit_log_service) so the stored
    // `perubahan` keeps the same {old, new} shape as every other audited module.
    logAudit("nomor_surat", id.toString(), "DELETE", existing.toJson(),
            {"isDibatalkan": true, "alasanPembatalan": alasan}, subject);

    return {id: existing.id, nomor: existing.nomor, alasanPembatalan: alasan};
}

# The pieces needed to form a letter number, resolved once and shared by both the create and the
# preview paths (so the number's "front half" logic lives in exactly one place).
#
# + prefix - the sys_config numbering prefix (e.g. "SK")
# + kodeKategori - the kategori_surat.kode (e.g. "DR-02")
# + tahun - the numbering year
type NomorGenContext record {|
    string prefix;
    string kodeKategori;
    int tahun;
|};

# Resolves the prefix (sys_config), the kategori code (validating the kategori exists and is not
# deleted), and the numbering year from the date — the shared front half of both create and
# preview. Callers must have already validated `tanggal` via `validateTanggal`.
#
# + kategoriSuratId - the kategori_surat id to resolve/validate
# + tanggal - a validated YYYY-MM-DD date
# + return - the resolved context, a VALIDATION_ERROR AppError (unknown kategori), or an error
function resolveNomorContext(int kategoriSuratId, string tanggal) returns NomorGenContext|error {
    int tahun = check yearFromTanggal(tanggal);
    models:KategoriSurat? kategori = check repositories:findKategoriSuratById(kategoriSuratId);
    if kategori is () {
        return utils:validationError("Kategori surat tidak ditemukan");
    }
    string prefix = check resolvePrefix();
    return {prefix: prefix, kodeKategori: kategori.kode, tahun: tahun};
}

# Resolves the numbering prefix from sys_config. The `prefix_nomor_surat` row is guaranteed to be
# seeded (swamedia_portal_v1_6.sql), so a missing/blank row is now treated as a serious
# configuration bug, NOT a condition to silently tolerate with a hardcoded fallback. The client
# still only ever sees the generic 500 message (per the API Response Standard); the specific root
# cause goes to the server log so ops can find it immediately instead of guessing from a generic
# error.
#
# + return - the trimmed numbering prefix, or an error
function resolvePrefix() returns string|error {
    string? prefix = check repositories:getPrefixNomorSurat();
    if prefix is () || prefix.trim().length() == 0 {
        log:printError("Konfigurasi sys_config.prefix_nomor_surat tidak ditemukan -- modul Daftar Surat "
                + "tidak dapat generate nomor tanpa konfigurasi ini, periksa seeding database");
        return utils:internalError("Terjadi kesalahan pada server, silakan coba lagi nanti");
    }
    return prefix.trim();
}

# Validates tanggal: required, valid YYYY-MM-DD, and no later than H+1 of the server date (a small
# tolerance for client/server timezone drift).
#
# + tanggal - the date string to validate (YYYY-MM-DD)
# + return - a VALIDATION_ERROR AppError if invalid, () if valid, or an error
function validateTanggal(string tanggal) returns models:AppError|error? {
    if !DATE_PATTERN.isFullMatch(tanggal) {
        return utils:validationError("Tanggal surat tidak valid, gunakan format YYYY-MM-DD");
    }
    time:Utc|time:Error parsed = time:utcFromString(tanggal + "T00:00:00Z");
    if parsed is time:Error {
        return utils:validationError("Tanggal surat tidak valid");
    }
    time:Utc maxAllowed = time:utcAddSeconds(time:utcNow(), 86400); // tolerate up to H+1
    if parsed[0] > maxAllowed[0] {
        return utils:validationError("Tanggal surat tidak boleh di masa depan");
    }
    return ();
}

# Validates tujuan: required, 1-150 characters (after trimming).
#
# + tujuan - the recipient string to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateTujuan(string tujuan) returns models:AppError? {
    if tujuan.length() < 1 || tujuan.length() > 150 {
        return utils:validationError("Tujuan wajib diisi, panjang 1-150 karakter");
    }
    return ();
}

# Validates perihal: required, 1-255 characters (after trimming).
#
# + perihal - the subject string to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validatePerihal(string perihal) returns models:AppError? {
    if perihal.length() < 1 || perihal.length() > 255 {
        return utils:validationError("Perihal wajib diisi, panjang 1-255 karakter");
    }
    return ();
}

# Ensures the referenced proyek exists and is not deleted (only when a proyek_id was supplied).
#
# + proyekId - the optional proyek id to validate
# + return - a VALIDATION_ERROR AppError if not found, () if valid/absent, or an error
function validateProyek(int? proyekId) returns models:AppError|error? {
    if proyekId is int {
        boolean ok = check repositories:proyekExistsActive(proyekId);
        if !ok {
            return utils:validationError("Proyek tidak ditemukan");
        }
    }
    return ();
}

# Parses the 4-digit year from a validated YYYY-MM-DD string.
#
# + tanggal - a validated YYYY-MM-DD date string
# + return - the 4-digit year, or an error
function yearFromTanggal(string tanggal) returns int|error {
    return int:fromString(tanggal.substring(0, 4));
}

# The current calendar year (server time), used as the default `tahun` list filter.
#
# + return - the current calendar year
function currentYear() returns int {
    time:Civil civil = time:utcToCivil(time:utcNow());
    return civil.year;
}

# Best-effort detection of a Postgres unique-constraint violation, so the number-generation race
# can be reported as CONFLICT 409 instead of a generic 500. Walks the error cause chain and looks
# for the tell-tale substrings / SQLSTATE 23505.
#
# + err - the error to inspect
# + return - true if it looks like a unique-constraint violation
isolated function isUniqueViolation(error err) returns boolean {
    error? current = err;
    while current is error {
        string msg = current.message().toLowerAscii();
        if msg.includes("duplicate key") || msg.includes("unique constraint")
                || msg.includes("uq_nomor_surat") || msg.includes("23505") {
            return true;
        }
        current = current.cause();
    }
    return false;
}

# Best-effort detection of a Postgres lock-timeout error (SQLSTATE 55P03) — raised when the
# `pg_advisory_xact_lock` call in `insertNomorSurat` could not acquire the per-(kategori, tahun)
# lock within the `SET LOCAL lock_timeout` window, most likely because a peer transaction is stuck
# or deadlocked. Walks the error cause chain, same approach as `isUniqueViolation`.
#
# + err - the error to inspect
# + return - true if it looks like a lock-timeout error
isolated function isLockTimeout(error err) returns boolean {
    error? current = err;
    while current is error {
        string msg = current.message().toLowerAscii();
        if msg.includes("lock timeout") || msg.includes("55p03") {
            return true;
        }
        current = current.cause();
    }
    return false;
}
