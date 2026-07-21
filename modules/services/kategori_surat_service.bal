import ballerina/lang.regexp;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Kategori Surat service =====
#
# Business rules for kategori surat (letter categories DR-01..DR-09). Domain failures are
# `models:AppError`; infrastructure failures propagate as plain `error`.

# Kode must match DR-XX exactly (DR- followed by exactly two digits): DR-01, DR-09 pass;
# DR-1, DR-100, dr-01 fail.
final regexp:RegExp KODE_PATTERN = re `DR-[0-9]{2}`;

# Lists non-deleted kategori surat with an optional search filter and pagination.
#
# + search - optional case-insensitive filter on kode or nama
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of kategori surat plus pagination metadata, or an error
public function getKategoriSurat(string? search, string? status, int page, int 'limit)
        returns models:KategoriSuratListResult|error {
    if status is string && status.trim().length() > 0 && !isValidKsStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:KategoriSurat[] items; int totalItems;|} result =
        check repositories:findKategoriSurat(search, status, safeLimit, offset);

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

# Fetches a single kategori surat by id.
#
# + id - the kategori surat id
# + return - the kategori surat, or a NOT_FOUND AppError if it does not exist, or an error
public function getKategoriSuratById(int id) returns models:KategoriSurat|error {
    models:KategoriSurat? kategori = check repositories:findKategoriSuratById(id);
    if kategori is () {
        return utils:notFoundError("Kategori surat dengan id " + id.toString() + " tidak ditemukan");
    }
    return kategori;
}

# Creates a new kategori surat (always non-default). Validates the kode pattern and the
# uniqueness of both kode and nama before inserting.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created kategori surat, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createKategoriSurat(models:KategoriSuratCreateRequest payload, string subject)
        returns models:KategoriSurat|error {
    string kode = payload.kode.trim();
    check validateKsKode(kode);
    string nama = payload.nama.trim();
    check validateKsNama(nama);

    string status = payload?.status ?: "AKTIF";
    if !isValidKsStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    check ensureKodeAvailable(kode, 0);
    check ensureNamaAvailable(nama, 0);

    return repositories:insertKategoriSurat(kode, nama, status, subject);
}

# Updates an existing kategori surat. `is_default` is never touched. Re-checks kode/nama
# uniqueness excluding the row itself.
#
# + id - the kategori surat id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated kategori surat, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateKategoriSurat(int id, models:KategoriSuratUpdateRequest payload, string subject)
        returns models:KategoriSurat|error {
    string kode = payload.kode.trim();
    check validateKsKode(kode);
    string nama = payload.nama.trim();
    check validateKsNama(nama);

    if !isValidKsStatus(payload.status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    models:KategoriSurat? existing = check repositories:findKategoriSuratById(id);
    if existing is () {
        return utils:notFoundError("Kategori surat dengan id " + id.toString() + " tidak ditemukan");
    }

    check ensureKodeAvailable(kode, id);
    check ensureNamaAvailable(nama, id);

    models:KategoriSurat? updated = check repositories:updateKategoriSurat(id, kode, nama, payload.status, subject);
    if updated is () {
        return utils:notFoundError("Kategori surat dengan id " + id.toString() + " tidak ditemukan");
    }
    return updated;
}

# Hard-deletes a kategori surat (no soft delete — see kategori_surat_repository.bal for why: `nama`
# carries a plain DB-level UNIQUE constraint, so a soft-deleted row would keep blocking reuse of its
# own name/code forever). Rejects built-in (default) categories outright, then guards against
# deleting a category ever used by a nomor_surat.
#
# + id - the kategori surat id to delete
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteKategoriSurat(int id) returns error? {
    models:KategoriSurat? existing = check repositories:findKategoriSuratById(id);
    if existing is () {
        return utils:notFoundError("Kategori surat dengan id " + id.toString() + " tidak ditemukan");
    }

    // (a) built-in categories can never be deleted — short-circuit before any dependency check.
    if existing.isDefault {
        return utils:conflictError("Kategori surat bawaan (default) tidak dapat dihapus");
    }

    // (b) otherwise, block deletion while it is (or ever was) referenced by a nomor_surat.
    boolean referenced = check repositories:isKategoriSuratReferenced(id);
    if referenced {
        return utils:conflictError("Kategori surat tidak dapat dihapus karena sudah dipakai pada penomoran surat");
    }

    boolean deleted = check repositories:deleteKategoriSurat(id);
    if !deleted {
        return utils:notFoundError("Kategori surat dengan id " + id.toString() + " tidak ditemukan");
    }
    return ();
}

# Validates kode against the DR-XX pattern.
#
# + kode - the kategori surat code to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateKsKode(string kode) returns models:AppError? {
    if !KODE_PATTERN.isFullMatch(kode) {
        return utils:validationError("Format kode harus DR-XX (contoh: DR-01)");
    }
    return ();
}

# Validates nama: required, maximum 150 characters (after trimming).
#
# + nama - the kategori surat name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateKsNama(string nama) returns models:AppError? {
    if nama.length() < 1 {
        return utils:validationError("Nama kategori surat wajib diisi");
    }
    if nama.length() > 150 {
        return utils:validationError("Nama kategori surat maksimal 150 karakter");
    }
    return ();
}

function isValidKsStatus(string status) returns boolean {
    return status == "AKTIF" || status == "TIDAK_AKTIF";
}

# Returns a CONFLICT AppError if the kode is already taken by another category.
#
# + kode - the kode to check
# + excludeId - a kategori surat id to exclude from the check (0 = none)
# + return - a CONFLICT AppError if taken, () if available, or an error
function ensureKodeAvailable(string kode, int excludeId) returns models:AppError|error? {
    boolean exists = check repositories:kategoriSuratKodeExists(kode, excludeId);
    if exists {
        return utils:conflictError("Kode kategori surat sudah digunakan");
    }
    return ();
}

# Returns a CONFLICT AppError if the nama is already taken by another category.
#
# + nama - the nama to check
# + excludeId - a kategori surat id to exclude from the check (0 = none)
# + return - a CONFLICT AppError if taken, () if available, or an error
function ensureNamaAvailable(string nama, int excludeId) returns models:AppError|error? {
    boolean exists = check repositories:kategoriSuratNamaExists(nama, excludeId);
    if exists {
        return utils:conflictError("Nama kategori surat sudah digunakan");
    }
    return ();
}
