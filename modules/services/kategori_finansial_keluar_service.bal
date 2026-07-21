import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Kategori Finansial Keluar service =====
#
# CRUD business rules for kategori_finansial_keluar (the category master shared by Pembayaran and
# Pengeluaran Perusahaan). Domain failures are `models:AppError`; infrastructure failures propagate
# as plain `error`. `kode` is unique; the table has no soft-delete column, so delete is physical and
# guarded against categories still referenced by an active pembayaran/pengeluaran.

# Lists kategori rows with optional filters and pagination.
#
# + search - optional case-insensitive filter on kode/nama
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, a VALIDATION_ERROR AppError, or an error
public function getKategoriFinansialKeluar(string? search, string? status, int page, int 'limit)
        returns models:KategoriFinansialKeluarListResult|error {
    if status is string && status.trim().length() > 0 && !isValidKategoriFinansialStatus(status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:KategoriFinansialKeluar[] items; int totalItems;|} result =
        check repositories:findKategoriFinansialKeluar(search, status, safeLimit, offset);

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

# Fetches a single kategori by id.
#
# + id - the kategori_finansial_keluar id
# + return - the kategori, a NOT_FOUND AppError if it does not exist, or an error
public function getKategoriFinansialKeluarById(int id) returns models:KategoriFinansialKeluar|error {
    models:KategoriFinansialKeluar? row = check repositories:findKategoriFinansialKeluarById(id);
    if row is () {
        return utils:notFoundError("Kategori finansial keluar dengan id " + id.toString() + " tidak ditemukan");
    }
    return row;
}

# Creates a kategori: validates kode/nama/status and rejects a duplicate kode.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created kategori, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createKategoriFinansialKeluar(models:KategoriFinansialKeluarCreateRequest payload, string subject)
        returns models:KategoriFinansialKeluar|error {
    string kode = payload.kode.trim();
    string nama = payload.nama.trim();
    check validateKategoriFinansialFields(kode, nama);

    string status = payload?.status ?: "AKTIF";
    if !isValidKategoriFinansialStatus(status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    if check repositories:kategoriFinansialKeluarKodeExists(kode, 0) {
        return utils:conflictError("Kode kategori finansial keluar sudah digunakan");
    }

    models:KategoriFinansialKeluar created = check repositories:insertKategoriFinansialKeluar(kode, nama, status, subject);
    logAudit("kategori_finansial_keluar", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates a kategori: same validations as create; the row being updated is excluded from the kode
# uniqueness check.
#
# + id - the kategori_finansial_keluar id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - the updated kategori, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateKategoriFinansialKeluar(int id, models:KategoriFinansialKeluarUpdateRequest payload,
        string subject) returns models:KategoriFinansialKeluar|error {
    string kode = payload.kode.trim();
    string nama = payload.nama.trim();
    check validateKategoriFinansialFields(kode, nama);

    if !isValidKategoriFinansialStatus(payload.status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    models:KategoriFinansialKeluar? existing = check repositories:findKategoriFinansialKeluarById(id);
    if existing is () {
        return utils:notFoundError("Kategori finansial keluar dengan id " + id.toString() + " tidak ditemukan");
    }
    if check repositories:kategoriFinansialKeluarKodeExists(kode, id) {
        return utils:conflictError("Kode kategori finansial keluar sudah digunakan");
    }

    models:KategoriFinansialKeluar? updated =
        check repositories:updateKategoriFinansialKeluar(id, kode, nama, payload.status);
    if updated is () {
        return utils:notFoundError("Kategori finansial keluar dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("kategori_finansial_keluar", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Physically deletes a kategori after ensuring it exists and is not referenced by any active
# pembayaran/pengeluaran.
#
# + id - the kategori_finansial_keluar id to delete
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteKategoriFinansialKeluar(int id, string subject) returns error? {
    models:KategoriFinansialKeluar? existing = check repositories:findKategoriFinansialKeluarById(id);
    if existing is () {
        return utils:notFoundError("Kategori finansial keluar dengan id " + id.toString() + " tidak ditemukan");
    }
    if check repositories:isKategoriFinansialKeluarReferenced(id) {
        return utils:conflictError(
            "Kategori tidak dapat dihapus karena masih dipakai pada Pembayaran/Pengeluaran Perusahaan");
    }
    boolean deleted = check repositories:deleteKategoriFinansialKeluar(id);
    if !deleted {
        return utils:notFoundError("Kategori finansial keluar dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("kategori_finansial_keluar", id.toString(), "DELETE", existing.toJson(), (), subject);
    return ();
}

# Validates kode (1-20) and nama (1-100).
#
# + kode - the code to validate
# + nama - the name to validate
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateKategoriFinansialFields(string kode, string nama) returns models:AppError? {
    if kode.length() < 1 || kode.length() > 20 {
        return utils:validationError("Kode kategori wajib diisi, panjang 1-20 karakter");
    }
    if nama.length() < 1 || nama.length() > 100 {
        return utils:validationError("Nama kategori wajib diisi, panjang 1-100 karakter");
    }
    return ();
}

# Validates a kategori finansial keluar status value.
#
# + status - the status to check
# + return - true if AKTIF / TIDAK_AKTIF
function isValidKategoriFinansialStatus(string status) returns boolean {
    return status == "AKTIF" || status == "TIDAK_AKTIF";
}
