import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Finansial — Pengeluaran Perusahaan service =====
#
# Business rules for pengeluaran perusahaan (unit-tied internal cash-out) — the twin of pembayaran,
# keyed on a unit instead of a proyek. Domain failures are `models:AppError`; infrastructure failures
# propagate as plain `error`. Reuses the module-scoped helpers `validateNilaiPositif`, `ensureKategoriExists`
# and `isValidApprovalStatus` from `pembayaran_service` (same `services` module) rather than
# redeclaring them. The SAME approval-authorization deferral described in `pembayaran_service` applies
# here — the state machine is enforced, but who may approve is not yet role-checked.

# Lists non-deleted pengeluaran with optional filters and pagination.
#
# + search - optional case-insensitive filter on keterangan / unit name
# + unitId - optional exact unit_id filter
# + kategoriId - optional exact kategori_id filter
# + status - optional exact status filter (PENGAJUAN / APPROVED / REJECTED)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, a VALIDATION_ERROR AppError, or an error
public function getPengeluaran(string? search, int? unitId, int? kategoriId, string? status, int page,
        int 'limit) returns models:PengeluaranListResult|error {
    if status is string && status.trim().length() > 0 && !isValidApprovalStatus(status) {
        return utils:validationError("Status harus PENGAJUAN, APPROVED, atau REJECTED");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:PengeluaranPerusahaan[] items; int totalItems;|} result =
        check repositories:findPengeluaran(search, unitId, kategoriId, status, safeLimit, offset);

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

# Fetches a single pengeluaran by id.
#
# + id - the pengeluaran id
# + return - the pengeluaran, a NOT_FOUND AppError if it does not exist, or an error
public function getPengeluaranById(int id) returns models:PengeluaranPerusahaan|error {
    models:PengeluaranPerusahaan? pengeluaran = check repositories:findPengeluaranById(id);
    if pengeluaran is () {
        return utils:notFoundError("Pengeluaran dengan id " + id.toString() + " tidak ditemukan");
    }
    return pengeluaran;
}

# Creates a pengeluaran (always status PENGAJUAN): validates the amount, dates, and the unit +
# kategori references.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created pengeluaran, a VALIDATION_ERROR AppError, or an error
public function createPengeluaran(models:PengeluaranCreateRequest payload, string subject)
        returns models:PengeluaranPerusahaan|error {
    check validateNilaiPositif(payload.nilai);
    string tanggalPengajuan = check validateRequiredDate(payload.tanggalPengajuan, "Tanggal pengajuan");
    string? tanggalRealisasi = check validateProyekDate(payload?.tanggalRealisasi, "Tanggal realisasi");
    string? keterangan = normalizeProyekText(payload?.keterangan);

    boolean unitOk = check repositories:unitExistsActive(payload.unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    check ensureKategoriExists(payload.kategoriId);

    models:PengeluaranPerusahaan created = check repositories:insertPengeluaran(payload.unitId,
            payload.kategoriId, payload.nilai, tanggalPengajuan, tanggalRealisasi, keterangan, subject);
    logAudit("pengeluaran_perusahaan", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates a pengeluaran (only while PENGAJUAN/REJECTED — an APPROVED row is locked). The edit
# re-opens the request (status back to PENGAJUAN, approval fields cleared) inside the repository.
#
# + id - the pengeluaran id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated pengeluaran, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updatePengeluaran(int id, models:PengeluaranUpdateRequest payload, string subject)
        returns models:PengeluaranPerusahaan|error {
    check validateNilaiPositif(payload.nilai);
    string tanggalPengajuan = check validateRequiredDate(payload.tanggalPengajuan, "Tanggal pengajuan");
    string? tanggalRealisasi = check validateProyekDate(payload?.tanggalRealisasi, "Tanggal realisasi");
    string? keterangan = normalizeProyekText(payload?.keterangan);

    models:PengeluaranPerusahaan? existing = check repositories:findPengeluaranById(id);
    if existing is () {
        return utils:notFoundError("Pengeluaran dengan id " + id.toString() + " tidak ditemukan");
    }
    if existing.status == "APPROVED" {
        return utils:conflictError("Pengeluaran yang sudah APPROVED tidak dapat diubah");
    }
    boolean unitOk = check repositories:unitExistsActive(payload.unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    check ensureKategoriExists(payload.kategoriId);

    models:PengeluaranPerusahaan? updated = check repositories:updatePengeluaran(id, payload.unitId,
            payload.kategoriId, payload.nilai, tanggalPengajuan, tanggalRealisasi, keterangan, subject);
    if updated is () {
        return utils:notFoundError("Pengeluaran dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("pengeluaran_perusahaan", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Approves a pengeluaran. Only a PENGAJUAN row can be approved (see the module note on the authz
# deferral in `pembayaran_service`).
#
# + id - the pengeluaran id
# + payload - the approve request body (optional realization date + note)
# + subject - the approver's `sub` claim
# + return - the approved pengeluaran, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function approvePengeluaran(int id, models:ApproveRequest payload, string subject)
        returns models:PengeluaranPerusahaan|error {
    models:PengeluaranPerusahaan pending = check ensurePendingPengeluaran(id);
    string? tanggalRealisasi = check validateProyekDate(payload?.tanggalRealisasi, "Tanggal realisasi");
    string? catatan = normalizeProyekText(payload?.catatan);

    models:PengeluaranPerusahaan? approved =
        check repositories:approvePengeluaran(id, subject, tanggalRealisasi, catatan);
    if approved is () {
        return utils:conflictError("Pengeluaran tidak dapat di-approve (mungkin statusnya sudah berubah)");
    }
    logAudit("pengeluaran_perusahaan", id.toString(), "UPDATE", pending.toJson(), approved.toJson(), subject);
    return approved;
}

# Rejects a pengeluaran. Only a PENGAJUAN row can be rejected.
#
# + id - the pengeluaran id
# + payload - the reject request body (optional note)
# + subject - the rejecter's `sub` claim
# + return - the rejected pengeluaran, a NOT_FOUND/CONFLICT AppError, or an error
public function rejectPengeluaran(int id, models:RejectRequest payload, string subject)
        returns models:PengeluaranPerusahaan|error {
    models:PengeluaranPerusahaan pending = check ensurePendingPengeluaran(id);
    string? catatan = normalizeProyekText(payload?.catatan);

    models:PengeluaranPerusahaan? rejected = check repositories:rejectPengeluaran(id, subject, catatan);
    if rejected is () {
        return utils:conflictError("Pengeluaran tidak dapat di-reject (mungkin statusnya sudah berubah)");
    }
    logAudit("pengeluaran_perusahaan", id.toString(), "UPDATE", pending.toJson(), rejected.toJson(), subject);
    return rejected;
}

# Soft-deletes a pengeluaran.
#
# + id - the pengeluaran id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deletePengeluaran(int id, string subject) returns error? {
    models:PengeluaranPerusahaan? existing = check repositories:findPengeluaranById(id);
    if existing is () {
        return utils:notFoundError("Pengeluaran dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean deleted = check repositories:softDeletePengeluaran(id, subject);
    if !deleted {
        return utils:notFoundError("Pengeluaran dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("pengeluaran_perusahaan", id.toString(), "DELETE", existing.toJson(), (), subject);
    return ();
}

# Loads a pengeluaran and asserts it is PENGAJUAN (approvable/rejectable). Shared by approve/reject.
#
# + id - the pengeluaran id
# + return - the pending pengeluaran, a NOT_FOUND/CONFLICT AppError, or an error
function ensurePendingPengeluaran(int id) returns models:PengeluaranPerusahaan|error {
    models:PengeluaranPerusahaan? existing = check repositories:findPengeluaranById(id);
    if existing is () {
        return utils:notFoundError("Pengeluaran dengan id " + id.toString() + " tidak ditemukan");
    }
    if existing.status != "PENGAJUAN" {
        return utils:conflictError("Hanya pengeluaran berstatus PENGAJUAN yang dapat di-approve/reject");
    }
    return existing;
}
