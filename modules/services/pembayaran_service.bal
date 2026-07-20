import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Finansial — Pembayaran service =====
#
# Business rules for pembayaran (project-tied cash-out) + its approval workflow. Domain failures are
# `models:AppError`; infrastructure failures propagate as plain `error`.
#
# APPROVAL AUTHORIZATION IS DEFERRED. Schema implementation note #8 says only a Direktur-Utama-unit
# karyawan holding `role_permission.can_approve` may approve — but role-based authorization does not
# exist anywhere in this codebase yet (see the same note in karyawan_service). Building a check only
# here would give false security while the rest of the app stays open, so this layer enforces the
# STATE MACHINE only (PENGAJUAN → APPROVED/REJECTED; editing a REJECTED row re-opens it to PENGAJUAN
# per note #5) and records `approved_by` from the caller's token. TODO(role-authz): gate approve/
# reject on can_approve + Direktur-Utama unit once role middleware exists.

# Lists non-deleted pembayaran with optional filters and pagination.
#
# + search - optional case-insensitive filter on keterangan / proyek code / proyek name
# + proyekId - optional exact proyek_id filter
# + kategoriId - optional exact kategori_id filter
# + status - optional exact status filter (PENGAJUAN / APPROVED / REJECTED)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, a VALIDATION_ERROR AppError, or an error
public function getPembayaran(string? search, int? proyekId, int? kategoriId, string? status, int page,
        int 'limit) returns models:PembayaranListResult|error {
    if status is string && status.trim().length() > 0 && !isValidApprovalStatus(status) {
        return utils:validationError("Status harus PENGAJUAN, APPROVED, atau REJECTED");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Pembayaran[] items; int totalItems;|} result =
        check repositories:findPembayaran(search, proyekId, kategoriId, status, safeLimit, offset);

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

# Fetches a single pembayaran by id.
#
# + id - the pembayaran id
# + return - the pembayaran, a NOT_FOUND AppError if it does not exist, or an error
public function getPembayaranById(int id) returns models:Pembayaran|error {
    models:Pembayaran? pembayaran = check repositories:findPembayaranById(id);
    if pembayaran is () {
        return utils:notFoundError("Pembayaran dengan id " + id.toString() + " tidak ditemukan");
    }
    return pembayaran;
}

# Creates a pembayaran (always status PENGAJUAN): validates the amount, dates, and the proyek +
# kategori references.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created pembayaran, a VALIDATION_ERROR AppError, or an error
public function createPembayaran(models:PembayaranCreateRequest payload, string subject)
        returns models:Pembayaran|error {
    check validateNilaiPositif(payload.nilai);
    string tanggalPengajuan = check validateRequiredDate(payload.tanggalPengajuan, "Tanggal pengajuan");
    string? tanggalRealisasi = check validateProyekDate(payload?.tanggalRealisasi, "Tanggal realisasi");
    string? keterangan = normalizeProyekText(payload?.keterangan);

    boolean proyekOk = check repositories:proyekExistsActive(payload.proyekId);
    if !proyekOk {
        return utils:validationError("Proyek tidak ditemukan");
    }
    check ensureKategoriExists(payload.kategoriId);

    return repositories:insertPembayaran(payload.proyekId, payload.kategoriId, payload.nilai,
            tanggalPengajuan, tanggalRealisasi, keterangan, subject);
}

# Updates a pembayaran (only while PENGAJUAN/REJECTED — an APPROVED row is locked). The edit re-opens
# the request (status back to PENGAJUAN, approval fields cleared) inside the repository.
#
# + id - the pembayaran id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated pembayaran, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updatePembayaran(int id, models:PembayaranUpdateRequest payload, string subject)
        returns models:Pembayaran|error {
    check validateNilaiPositif(payload.nilai);
    string tanggalPengajuan = check validateRequiredDate(payload.tanggalPengajuan, "Tanggal pengajuan");
    string? tanggalRealisasi = check validateProyekDate(payload?.tanggalRealisasi, "Tanggal realisasi");
    string? keterangan = normalizeProyekText(payload?.keterangan);

    models:Pembayaran? existing = check repositories:findPembayaranById(id);
    if existing is () {
        return utils:notFoundError("Pembayaran dengan id " + id.toString() + " tidak ditemukan");
    }
    if existing.status == "APPROVED" {
        return utils:conflictError("Pembayaran yang sudah APPROVED tidak dapat diubah");
    }
    boolean proyekOk = check repositories:proyekExistsActive(payload.proyekId);
    if !proyekOk {
        return utils:validationError("Proyek tidak ditemukan");
    }
    check ensureKategoriExists(payload.kategoriId);

    models:Pembayaran? updated = check repositories:updatePembayaran(id, payload.proyekId, payload.kategoriId,
            payload.nilai, tanggalPengajuan, tanggalRealisasi, keterangan, subject);
    if updated is () {
        return utils:notFoundError("Pembayaran dengan id " + id.toString() + " tidak ditemukan");
    }
    return updated;
}

# Approves a pembayaran. Only a PENGAJUAN row can be approved (see the module note on why the
# approver's authority is not yet role-checked).
#
# + id - the pembayaran id
# + payload - the approve request body (optional realization date + note)
# + subject - the approver's `sub` claim
# + return - the approved pembayaran, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function approvePembayaran(int id, models:ApproveRequest payload, string subject)
        returns models:Pembayaran|error {
    _ = check ensurePending(id);
    string? tanggalRealisasi = check validateProyekDate(payload?.tanggalRealisasi, "Tanggal realisasi");
    string? catatan = normalizeProyekText(payload?.catatan);

    models:Pembayaran? approved = check repositories:approvePembayaran(id, subject, tanggalRealisasi, catatan);
    if approved is () {
        return utils:conflictError("Pembayaran tidak dapat di-approve (mungkin statusnya sudah berubah)");
    }
    return approved;
}

# Rejects a pembayaran. Only a PENGAJUAN row can be rejected.
#
# + id - the pembayaran id
# + payload - the reject request body (optional note)
# + subject - the rejecter's `sub` claim
# + return - the rejected pembayaran, a NOT_FOUND/CONFLICT AppError, or an error
public function rejectPembayaran(int id, models:RejectRequest payload, string subject)
        returns models:Pembayaran|error {
    _ = check ensurePending(id);
    string? catatan = normalizeProyekText(payload?.catatan);

    models:Pembayaran? rejected = check repositories:rejectPembayaran(id, subject, catatan);
    if rejected is () {
        return utils:conflictError("Pembayaran tidak dapat di-reject (mungkin statusnya sudah berubah)");
    }
    return rejected;
}

# Soft-deletes a pembayaran.
#
# + id - the pembayaran id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deletePembayaran(int id, string subject) returns error? {
    models:Pembayaran? existing = check repositories:findPembayaranById(id);
    if existing is () {
        return utils:notFoundError("Pembayaran dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean deleted = check repositories:softDeletePembayaran(id, subject);
    if !deleted {
        return utils:notFoundError("Pembayaran dengan id " + id.toString() + " tidak ditemukan");
    }
    return ();
}

# Loads a pembayaran and asserts it is PENGAJUAN (approvable/rejectable). Shared by approve/reject.
#
# + id - the pembayaran id
# + return - the pending pembayaran, a NOT_FOUND/CONFLICT AppError, or an error
function ensurePending(int id) returns models:Pembayaran|error {
    models:Pembayaran? existing = check repositories:findPembayaranById(id);
    if existing is () {
        return utils:notFoundError("Pembayaran dengan id " + id.toString() + " tidak ditemukan");
    }
    if existing.status != "PENGAJUAN" {
        return utils:conflictError("Hanya pembayaran berstatus PENGAJUAN yang dapat di-approve/reject");
    }
    return existing;
}

# Fails with VALIDATION_ERROR if the referenced kategori_finansial_keluar doesn't exist (or is
# inactive). Module-scoped, so `pengeluaran_perusahaan_service` reuses this same helper.
#
# + kategoriId - the kategori_finansial_keluar id
# + return - a VALIDATION_ERROR AppError if missing, () if ok, or an error
function ensureKategoriExists(int kategoriId) returns models:AppError|error? {
    boolean ok = check repositories:kategoriFinansialKeluarExistsActive(kategoriId);
    if !ok {
        return utils:validationError("Kategori finansial tidak ditemukan");
    }
    return ();
}

# Validates a cash-out amount: must be > 0. Module-scoped, reused by pengeluaran_perusahaan_service.
#
# + nilai - the amount to validate
# + return - a VALIDATION_ERROR AppError if non-positive, else ()
function validateNilaiPositif(decimal nilai) returns models:AppError? {
    if nilai <= 0d {
        return utils:validationError("Nilai harus lebih besar dari 0");
    }
    return ();
}

# Validates an approval-workflow status filter value.
#
# + status - the status to check
# + return - true if PENGAJUAN / APPROVED / REJECTED
function isValidApprovalStatus(string status) returns boolean {
    return status == "PENGAJUAN" || status == "APPROVED" || status == "REJECTED";
}
