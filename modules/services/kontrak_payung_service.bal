import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Kontrak Payung service =====
#
# Business rules and validation for Kontrak Payung (and its per-role price lines). Domain failures
# are `models:AppError`; infrastructure failures propagate as plain `error`. Date validation and
# free-text normalization reuse `validateProyekDate`/`normalizeProyekField`/`normalizeProyekText`
# from proyek_service, and the unique-constraint race is recognised with `isUniqueViolation` from
# nomor_surat_service (all same-module reuse — no redeclaration).

final string[] KONTRAK_TIPE_HARGA_VALID = ["PER_BULAN", "PER_PROJECT"];

# Lists non-deleted kontrak payung with optional filters and pagination.
#
# + search - optional case-insensitive filter on no_kontrak_payung or nama_kontrak
# + customerId - optional exact customer_id filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, or an error
public function getKontrakPayung(string? search, int? customerId, int page, int 'limit)
        returns models:KontrakPayungListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:KontrakPayung[] items; int totalItems;|} result =
        check repositories:findKontrakPayung(search, customerId, safeLimit, offset);

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

# Fetches a single kontrak payung (with its price lines) by id.
#
# + id - the kontrak payung id
# + return - the contract, a NOT_FOUND AppError if it does not exist, or an error
public function getKontrakPayungById(int id) returns models:KontrakPayung|error {
    models:KontrakPayung? kontrak = check repositories:findKontrakPayungById(id);
    if kontrak is () {
        return utils:notFoundError("Kontrak payung dengan id " + id.toString() + " tidak ditemukan");
    }
    return kontrak;
}

# Creates a kontrak payung with its price lines: validates every field + FK reference, the number's
# uniqueness, then delegates the atomic contract + price-line insert to the repository.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created contract, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createKontrakPayung(models:KontrakPayungCreateRequest payload, string subject)
        returns models:KontrakPayung|error {
    string noKontrak = payload.noKontrakPayung.trim();
    string namaKontrak = payload.namaKontrak.trim();
    check validateNoKontrak(noKontrak);
    check validateNamaKontrak(namaKontrak);

    string tanggalKontrak = check validateRequiredDate(payload.tanggalKontrak, "Tanggal kontrak");
    string tanggalMulai = check validateRequiredDate(payload.tanggalMulai, "Tanggal mulai");
    string tanggalSelesai = check validateRequiredDate(payload.tanggalSelesai, "Tanggal selesai");
    check validatePeriodeKontrak(tanggalMulai, tanggalSelesai);

    boolean customerOk = check repositories:customerExistsActive(payload.customerId);
    if !customerOk {
        return utils:validationError("Customer tidak ditemukan");
    }
    models:KontrakPayungHargaRoleInput[] hargaRole = check validateHargaRole(payload?.hargaRole ?: []);

    boolean dup = check repositories:kontrakPayungNoExists(noKontrak, 0);
    if dup {
        return utils:conflictError("No kontrak payung sudah digunakan");
    }

    models:KontrakPayung|error created = repositories:insertKontrakPayung(payload.customerId, noKontrak,
            namaKontrak, tanggalKontrak, tanggalMulai, tanggalSelesai, hargaRole, subject);
    if created is error {
        if isUniqueViolation(created) {
            return utils:conflictError("No kontrak payung sudah digunakan");
        }
        return created;
    }
    logAudit("kontrak_payung", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates a kontrak payung. Price lines have replace-or-leave semantics: when `hargaRole` is present
# in the payload the whole set is replaced, when omitted the existing lines are kept.
#
# + id - the kontrak payung id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated contract, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateKontrakPayung(int id, models:KontrakPayungUpdateRequest payload, string subject)
        returns models:KontrakPayung|error {
    string noKontrak = payload.noKontrakPayung.trim();
    string namaKontrak = payload.namaKontrak.trim();
    check validateNoKontrak(noKontrak);
    check validateNamaKontrak(namaKontrak);

    string tanggalKontrak = check validateRequiredDate(payload.tanggalKontrak, "Tanggal kontrak");
    string tanggalMulai = check validateRequiredDate(payload.tanggalMulai, "Tanggal mulai");
    string tanggalSelesai = check validateRequiredDate(payload.tanggalSelesai, "Tanggal selesai");
    check validatePeriodeKontrak(tanggalMulai, tanggalSelesai);

    models:KontrakPayung? existing = check repositories:findKontrakPayungById(id);
    if existing is () {
        return utils:notFoundError("Kontrak payung dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean customerOk = check repositories:customerExistsActive(payload.customerId);
    if !customerOk {
        return utils:validationError("Customer tidak ditemukan");
    }

    boolean replaceHargaRole = payload?.hargaRole !is ();
    models:KontrakPayungHargaRoleInput[] hargaRole = check validateHargaRole(payload?.hargaRole ?: []);

    boolean dup = check repositories:kontrakPayungNoExists(noKontrak, id);
    if dup {
        return utils:conflictError("No kontrak payung sudah digunakan");
    }

    models:KontrakPayung?|error updated = repositories:updateKontrakPayung(id, payload.customerId, noKontrak,
            namaKontrak, tanggalKontrak, tanggalMulai, tanggalSelesai, replaceHargaRole, hargaRole, subject);
    if updated is error {
        if isUniqueViolation(updated) {
            return utils:conflictError("No kontrak payung sudah digunakan");
        }
        return updated;
    }
    if updated is () {
        return utils:notFoundError("Kontrak payung dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("kontrak_payung", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Soft-deletes a kontrak payung. Refuses (CONFLICT) if any active proyek or kontrak biasa still
# references it.
#
# + id - the kontrak payung id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteKontrakPayung(int id, string subject) returns error? {
    models:KontrakPayung? existing = check repositories:findKontrakPayungById(id);
    if existing is () {
        return utils:notFoundError("Kontrak payung dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean referenced = check repositories:isKontrakPayungReferenced(id);
    if referenced {
        return utils:conflictError(
                "Kontrak payung tidak dapat dihapus karena masih dipakai oleh proyek atau kontrak biasa");
    }
    boolean deleted = check repositories:softDeleteKontrakPayung(id, subject);
    if !deleted {
        return utils:notFoundError("Kontrak payung dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("kontrak_payung", id.toString(), "DELETE", existing.toJson(), (), subject);
    return ();
}

# Returns active kontrak payung options for the Proyek-form dropdown.
#
# + customerId - optional exact customer_id filter
# + search - optional case-insensitive filter on no_kontrak_payung or nama_kontrak
# + return - the dropdown options (max 100), or an error
public function getKontrakPayungDropdown(int? customerId, string? search)
        returns models:KontrakPayungDropdownItem[]|error {
    return repositories:getKontrakPayungDropdown(customerId, search);
}

# Validates no_kontrak_payung: required, max 50 characters.
#
# + noKontrak - the trimmed contract number
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateNoKontrak(string noKontrak) returns models:AppError? {
    if noKontrak.length() < 1 || noKontrak.length() > 50 {
        return utils:validationError("No kontrak payung wajib diisi, panjang maksimal 50 karakter");
    }
    return ();
}

# Validates nama_kontrak: required, max 150 characters.
#
# + namaKontrak - the trimmed contract name
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateNamaKontrak(string namaKontrak) returns models:AppError? {
    if namaKontrak.length() < 1 || namaKontrak.length() > 150 {
        return utils:validationError("Nama kontrak wajib diisi, panjang maksimal 150 karakter");
    }
    return ();
}

# Validates a REQUIRED date field: not blank, format YYYY-MM-DD, and parseable. Delegates the
# format/parse check to proyek_service's `validateProyekDate` (which returns () for blank), then
# enforces presence.
#
# + value - the raw date string
# + label - the field label used in error messages
# + return - the trimmed date, a VALIDATION_ERROR AppError if blank/invalid, or an error
function validateRequiredDate(string value, string label) returns string|models:AppError|error {
    string? validated = check validateProyekDate(value, label);
    if validated is () {
        return utils:validationError(label + " wajib diisi");
    }
    return validated;
}

# Validates the coverage period: tanggal_selesai may not precede tanggal_mulai (mirrors
# `ck_kontrak_payung_tanggal`). Both are already-validated YYYY-MM-DD strings, so a lexicographic
# comparison is a correct chronological one.
#
# + tanggalMulai - the coverage start date
# + tanggalSelesai - the coverage end date
# + return - a VALIDATION_ERROR AppError if the period is inverted, else ()
function validatePeriodeKontrak(string tanggalMulai, string tanggalSelesai) returns models:AppError? {
    if tanggalSelesai < tanggalMulai {
        return utils:validationError("Tanggal selesai tidak boleh sebelum tanggal mulai");
    }
    return ();
}

# Validates every price line: role exists, tipe_harga is valid, nilai > 0, keterangan within length.
# Returns the (normalized) lines ready for the repository.
#
# + lines - the price lines from the payload
# + return - the normalized price lines, a VALIDATION_ERROR AppError, or an error
function validateHargaRole(models:KontrakPayungHargaRoleInput[] lines)
        returns models:KontrakPayungHargaRoleInput[]|error {
    models:KontrakPayungHargaRoleInput[] normalized = [];
    foreach models:KontrakPayungHargaRoleInput line in lines {
        if !isValidTipeHarga(line.tipeHarga) {
            return utils:validationError("Tipe harga harus PER_BULAN atau PER_PROJECT");
        }
        if line.nilai <= 0d {
            return utils:validationError("Nilai harga role harus lebih besar dari 0");
        }
        boolean roleOk = check repositories:projectRoleExistsActive(line.roleId);
        if !roleOk {
            return utils:validationError("Project role dengan id " + line.roleId.toString() + " tidak ditemukan");
        }
        string? keterangan = check normalizeProyekField(line?.keterangan, 255, "Keterangan harga role");
        normalized.push({
            roleId: line.roleId,
            tipeHarga: line.tipeHarga,
            nilai: line.nilai,
            keterangan: keterangan
        });
    }
    return normalized;
}

function isValidTipeHarga(string tipeHarga) returns boolean {
    foreach string t in KONTRAK_TIPE_HARGA_VALID {
        if t == tipeHarga {
            return true;
        }
    }
    return false;
}
