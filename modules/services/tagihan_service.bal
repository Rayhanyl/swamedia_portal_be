import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Finansial — Tagihan service =====
#
# Business rules for tagihan (invoices) + their `status_tagihan` history. Domain failures are
# `models:AppError`; infrastructure failures propagate as plain `error`. Date validation and
# free-text normalization reuse `validateRequiredDate` (from kontrak_payung_service) and
# `normalizeProyekText` (from proyek_service); the unique-constraint race is recognised with
# `isUniqueViolation` (from nomor_surat_service) — all same-module reuse. Status changes (including
# the initial status at creation) are logged to `status_tagihan` entirely inside the repository.

final string[] TAGIHAN_VALID_STATUS = [
    "RENCANA", "BAST", "KIRIM_TAGIHAN", "LUNAS", "PELUANG", "TIDAK_TERTAGIH"
];

const string TAGIHAN_STATUS_DEFAULT = "RENCANA";

# Lists non-deleted tagihan with optional filters and pagination.
#
# + search - optional case-insensitive filter on no_tagihan
# + proyekId - optional exact proyek_id filter
# + statusAktif - optional exact status_aktif filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, a VALIDATION_ERROR AppError, or an error
public function getTagihan(string? search, int? proyekId, string? statusAktif, int page, int 'limit)
        returns models:TagihanListResult|error {
    if statusAktif is string && statusAktif.trim().length() > 0 && !isValidTagihanStatus(statusAktif) {
        return utils:validationError("Status tagihan tidak valid");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Tagihan[] items; int totalItems;|} result =
        check repositories:findTagihan(search, proyekId, statusAktif, safeLimit, offset);

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

# Fetches a single tagihan by id.
#
# + id - the tagihan id
# + return - the tagihan, a NOT_FOUND AppError if it does not exist, or an error
public function getTagihanById(int id) returns models:Tagihan|error {
    models:Tagihan? tagihan = check repositories:findTagihanById(id);
    if tagihan is () {
        return utils:notFoundError("Tagihan dengan id " + id.toString() + " tidak ditemukan");
    }
    return tagihan;
}

# Fetches the status-transition history of a tagihan.
#
# + id - the tagihan id
# + return - the status_tagihan rows, a NOT_FOUND AppError if the tagihan doesn't exist, or an error
public function getTagihanStatusHistory(int id) returns models:TagihanStatusHistory[]|error {
    models:Tagihan? tagihan = check repositories:findTagihanById(id);
    if tagihan is () {
        return utils:notFoundError("Tagihan dengan id " + id.toString() + " tidak ditemukan");
    }
    return repositories:findTagihanStatusHistory(id);
}

# Creates a tagihan: validates fields + the proyek reference + number uniqueness, then delegates the
# atomic insert (+ initial status_tagihan row) to the repository.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created tagihan, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createTagihan(models:TagihanCreateRequest payload, string subject, string? ipAddress = ()) returns models:Tagihan|error {
    string noTagihan = payload.noTagihan.trim();
    check validateNoTagihan(noTagihan);
    string tanggalTagihan = check validateRequiredDate(payload.tanggalTagihan, "Tanggal tagihan");
    check validateNilaiTagihan(payload.nilaiTagihan, payload?.nilaiDpp, payload?.ppn, payload?.pph);

    string statusAktif = payload?.statusAktif ?: TAGIHAN_STATUS_DEFAULT;
    if !isValidTagihanStatus(statusAktif) {
        return utils:validationError("Status tagihan tidak valid");
    }
    string? keterangan = normalizeProyekText(payload?.keterangan);

    boolean proyekOk = check repositories:proyekExistsActive(payload.proyekId);
    if !proyekOk {
        return utils:validationError("Proyek tidak ditemukan");
    }
    if check repositories:tagihanNoExists(noTagihan, 0) {
        return utils:conflictError("No tagihan sudah digunakan");
    }

    models:Tagihan|error created = repositories:insertTagihan(payload.proyekId, tanggalTagihan, noTagihan,
            keterangan, statusAktif, payload.nilaiTagihan, payload?.nilaiDpp, payload?.ppn, payload?.pph, subject);
    if created is error {
        if isUniqueViolation(created) {
            return utils:conflictError("No tagihan sudah digunakan");
        }
        return created;
    }
    logAudit("tagihan", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates a tagihan. Changing `statusAktif` logs a `status_tagihan` row (handled in the repository).
#
# + id - the tagihan id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated tagihan, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateTagihan(int id, models:TagihanUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:Tagihan|error {
    string noTagihan = payload.noTagihan.trim();
    check validateNoTagihan(noTagihan);
    string tanggalTagihan = check validateRequiredDate(payload.tanggalTagihan, "Tanggal tagihan");
    check validateNilaiTagihan(payload.nilaiTagihan, payload?.nilaiDpp, payload?.ppn, payload?.pph);
    if !isValidTagihanStatus(payload.statusAktif) {
        return utils:validationError("Status tagihan tidak valid");
    }
    string? keterangan = normalizeProyekText(payload?.keterangan);
    string? statusKomentar = normalizeProyekText(payload?.statusKomentar);

    models:Tagihan? existing = check repositories:findTagihanById(id);
    if existing is () {
        return utils:notFoundError("Tagihan dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean proyekOk = check repositories:proyekExistsActive(payload.proyekId);
    if !proyekOk {
        return utils:validationError("Proyek tidak ditemukan");
    }
    if check repositories:tagihanNoExists(noTagihan, id) {
        return utils:conflictError("No tagihan sudah digunakan");
    }

    boolean updated = check repositories:updateTagihan(id, payload.proyekId, tanggalTagihan, noTagihan,
            keterangan, payload.statusAktif, statusKomentar, payload.nilaiTagihan, payload?.nilaiDpp,
            payload?.ppn, payload?.pph, subject);
    if !updated {
        return utils:notFoundError("Tagihan dengan id " + id.toString() + " tidak ditemukan");
    }
    models:Tagihan result = check getTagihanById(id);
    logAudit("tagihan", id.toString(), "UPDATE", existing.toJson(), result.toJson(), subject, ipAddress);
    return result;
}

# Soft-deletes a tagihan.
#
# + id - the tagihan id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deleteTagihan(int id, string subject, string? ipAddress = ()) returns error? {
    models:Tagihan? existing = check repositories:findTagihanById(id);
    if existing is () {
        return utils:notFoundError("Tagihan dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean deleted = check repositories:softDeleteTagihan(id, subject);
    if !deleted {
        return utils:notFoundError("Tagihan dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("tagihan", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Validates no_tagihan: required, max 50 characters.
#
# + noTagihan - the trimmed invoice number
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateNoTagihan(string noTagihan) returns models:AppError? {
    if noTagihan.length() < 1 || noTagihan.length() > 50 {
        return utils:validationError("No tagihan wajib diisi, panjang maksimal 50 karakter");
    }
    return ();
}

# Validates the invoice amount (> 0) and the optional tax fields (non-negative when present).
#
# + nilaiTagihan - the invoiced amount
# + nilaiDpp - optional taxable base
# + ppn - optional VAT
# + pph - optional withholding tax
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateNilaiTagihan(decimal nilaiTagihan, decimal? nilaiDpp, decimal? ppn, decimal? pph)
        returns models:AppError? {
    if nilaiTagihan <= 0d {
        return utils:validationError("Nilai tagihan harus lebih besar dari 0");
    }
    if (nilaiDpp is decimal && nilaiDpp < 0d) || (ppn is decimal && ppn < 0d) || (pph is decimal && pph < 0d) {
        return utils:validationError("Nilai DPP/PPN/PPh tidak boleh negatif");
    }
    return ();
}

function isValidTagihanStatus(string status) returns boolean {
    foreach string s in TAGIHAN_VALID_STATUS {
        if s == status {
            return true;
        }
    }
    return false;
}
