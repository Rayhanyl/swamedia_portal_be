import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Finansial — Pencairan Tagihan service =====
#
# Business rules for pencairan (staged cash-in realization of a tagihan). Domain failures are
# `models:AppError`; infrastructure failures propagate as plain `error`. Every operation first
# confirms the parent tagihan exists (`requireTagihan`) and the pencairan id is scoped to that
# tagihan in the repository (cross-tagihan access reads as NOT_FOUND). The sum of a tagihan's
# non-cancelled (PARSIAL/FINAL) pencairan may not exceed its `nilaiTagihan`; a DIBATALKAN pencairan
# contributes nothing to that total. Date validation reuses `validateRequiredDate`
# (kontrak_payung_service) and free-text `normalizeProyekText` (proyek_service).

final string[] PENCAIRAN_VALID_STATUS = ["PARSIAL", "FINAL", "DIBATALKAN"];

# Lists all pencairan of a tagihan.
#
# + tagihanId - the parent tagihan id
# + return - the pencairan rows, a NOT_FOUND AppError if the tagihan doesn't exist, or an error
public function getPencairan(int tagihanId) returns models:PencairanTagihan[]|error {
    _ = check requireTagihan(tagihanId);
    return repositories:findPencairanByTagihan(tagihanId);
}

# Creates a pencairan under a tagihan.
#
# + tagihanId - the parent tagihan id
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created pencairan, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function createPencairan(int tagihanId, models:PencairanCreateRequest payload, string subject)
        returns models:PencairanTagihan|error {
    models:Tagihan tagihan = check requireTagihan(tagihanId);
    string tanggalPencairan = check validateRequiredDate(payload.tanggalPencairan, "Tanggal pencairan");
    check validatePencairan(payload.nilai, payload.status);
    check ensurePencairanTotalFits(tagihanId, payload.nilai, payload.status, tagihan.nilaiTagihan, 0);
    string? keterangan = normalizeProyekText(payload?.keterangan);

    models:PencairanTagihan created = check repositories:insertPencairan(tagihanId, tanggalPencairan,
            payload.nilai, payload.status, keterangan, subject);
    logAudit("pencairan_tagihan", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates a pencairan.
#
# + tagihanId - the parent tagihan id
# + id - the pencairan id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - the updated pencairan, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updatePencairan(int tagihanId, int id, models:PencairanUpdateRequest payload, string subject)
        returns models:PencairanTagihan|error {
    models:Tagihan tagihan = check requireTagihan(tagihanId);
    string tanggalPencairan = check validateRequiredDate(payload.tanggalPencairan, "Tanggal pencairan");
    check validatePencairan(payload.nilai, payload.status);

    models:PencairanTagihan? existing = check repositories:findPencairanById(id, tagihanId);
    if existing is () {
        return utils:notFoundError("Pencairan dengan id " + id.toString() + " tidak ditemukan");
    }
    check ensurePencairanTotalFits(tagihanId, payload.nilai, payload.status, tagihan.nilaiTagihan, id);
    string? keterangan = normalizeProyekText(payload?.keterangan);

    models:PencairanTagihan? updated = check repositories:updatePencairan(id, tagihanId, tanggalPencairan,
            payload.nilai, payload.status, keterangan);
    if updated is () {
        return utils:notFoundError("Pencairan dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("pencairan_tagihan", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Soft-deletes a pencairan.
#
# + tagihanId - the parent tagihan id
# + id - the pencairan id to delete
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - (), a NOT_FOUND AppError, or an error
public function deletePencairan(int tagihanId, int id, string subject) returns error? {
    _ = check requireTagihan(tagihanId);
    // Read the row before deleting purely so the audit entry can record what was removed.
    models:PencairanTagihan? existing = check repositories:findPencairanById(id, tagihanId);
    boolean deleted = check repositories:softDeletePencairan(id, tagihanId);
    if !deleted {
        return utils:notFoundError("Pencairan dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("pencairan_tagihan", id.toString(), "DELETE", existing is () ? () : existing.toJson(), (), subject);
    return ();
}

# Loads the parent tagihan or fails with NOT_FOUND. Shared by every pencairan operation so a
# pencairan can never be created/read/mutated under a missing (or soft-deleted) tagihan.
#
# + tagihanId - the tagihan id to load
# + return - the tagihan, a NOT_FOUND AppError if it doesn't exist, or an error
function requireTagihan(int tagihanId) returns models:Tagihan|error {
    models:Tagihan? tagihan = check repositories:findTagihanById(tagihanId);
    if tagihan is () {
        return utils:notFoundError("Tagihan dengan id " + tagihanId.toString() + " tidak ditemukan");
    }
    return tagihan;
}

# Validates nilai (> 0) and status (PARSIAL/FINAL/DIBATALKAN).
#
# + nilai - the disbursed amount
# + status - the pencairan status
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validatePencairan(decimal nilai, string status) returns models:AppError? {
    if nilai <= 0d {
        return utils:validationError("Nilai pencairan harus lebih besar dari 0");
    }
    if !isValidPencairanStatus(status) {
        return utils:validationError("Status pencairan harus PARSIAL, FINAL, atau DIBATALKAN");
    }
    return ();
}

# Fails with VALIDATION_ERROR if adding this pencairan would push the tagihan's realized total past
# its `nilaiTagihan`. A DIBATALKAN pencairan contributes nothing, so it skips the check entirely.
#
# + tagihanId - the tagihan id
# + nilai - the pencairan amount being added/updated
# + status - the pencairan status
# + nilaiTagihan - the tagihan's total amount (ceiling)
# + excludeId - a pencairan id to exclude from the running total (0 on insert; target id on update)
# + return - a VALIDATION_ERROR AppError if it would over-realize, () otherwise, or an error
function ensurePencairanTotalFits(int tagihanId, decimal nilai, string status, decimal nilaiTagihan,
        int excludeId) returns models:AppError|error? {
    if status == "DIBATALKAN" {
        return ();
    }
    decimal existingTotal = check repositories:sumActivePencairan(tagihanId, excludeId);
    if existingTotal + nilai > nilaiTagihan {
        return utils:validationError(
                "Total pencairan melebihi nilai tagihan (" + nilaiTagihan.toString() + ")");
    }
    return ();
}

function isValidPencairanStatus(string status) returns boolean {
    foreach string s in PENCAIRAN_VALID_STATUS {
        if s == status {
            return true;
        }
    }
    return false;
}
