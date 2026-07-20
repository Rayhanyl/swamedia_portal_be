import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Unit Share service =====
#
# Business rules and validation for unit_share (splitting a proyek's value across units). Domain
# failures are `models:AppError`; infrastructure failures propagate as plain `error`. Every
# operation first confirms the parent proyek exists (returning NOT_FOUND otherwise) and — because
# the share id is always scoped to that proyek in the repository — a share belonging to a different
# proyek is reported as NOT_FOUND, never leaked or mutated across proyek boundaries.

# Lists all shares of a proyek.
#
# + proyekId - the parent proyek id
# + return - the shares, a NOT_FOUND AppError if the proyek doesn't exist, or an error
public function getUnitShare(int proyekId) returns models:UnitShare[]|error {
    _ = check requireProyek(proyekId);
    return repositories:findUnitShareByProyek(proyekId);
}

# Creates a share under a proyek: validates the value/percentage, the unit reference, uniqueness of
# the (proyek, unit) pair, and that the proyek's total share stays within its `nilai_proyek`.
#
# + proyekId - the parent proyek id
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created share, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function createUnitShare(int proyekId, models:UnitShareCreateRequest payload, string subject)
        returns models:UnitShare|error {
    models:Proyek proyek = check requireProyek(proyekId);
    check validateUnitShareValue(payload.nilaiShare, payload?.persentase);
    check ensureUnitExists(payload.unitId);

    boolean dup = check repositories:unitShareUnitExists(proyekId, payload.unitId, 0);
    if dup {
        return utils:conflictError("Unit ini sudah memiliki share pada proyek tersebut");
    }
    check ensureShareTotalFits(proyekId, payload.nilaiShare, proyek.nilaiProyek, 0);

    return repositories:insertUnitShare(proyekId, payload.unitId, payload.nilaiShare, payload?.persentase,
            subject);
}

# Updates a share. Same validations as create; the share being updated is excluded from both the
# uniqueness and the running-total checks.
#
# + proyekId - the parent proyek id
# + id - the share id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated share, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateUnitShare(int proyekId, int id, models:UnitShareUpdateRequest payload, string subject)
        returns models:UnitShare|error {
    models:Proyek proyek = check requireProyek(proyekId);
    check validateUnitShareValue(payload.nilaiShare, payload?.persentase);
    check ensureUnitExists(payload.unitId);

    models:UnitShare? existing = check repositories:findUnitShareById(id, proyekId);
    if existing is () {
        return utils:notFoundError("Unit share dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean dup = check repositories:unitShareUnitExists(proyekId, payload.unitId, id);
    if dup {
        return utils:conflictError("Unit ini sudah memiliki share pada proyek tersebut");
    }
    check ensureShareTotalFits(proyekId, payload.nilaiShare, proyek.nilaiProyek, id);

    models:UnitShare? updated = check repositories:updateUnitShare(id, proyekId, payload.unitId,
            payload.nilaiShare, payload?.persentase, subject);
    if updated is () {
        return utils:notFoundError("Unit share dengan id " + id.toString() + " tidak ditemukan");
    }
    return updated;
}

# Soft-deletes a share.
#
# + proyekId - the parent proyek id
# + id - the share id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deleteUnitShare(int proyekId, int id, string subject) returns error? {
    _ = check requireProyek(proyekId);
    boolean deleted = check repositories:softDeleteUnitShare(id, proyekId, subject);
    if !deleted {
        return utils:notFoundError("Unit share dengan id " + id.toString() + " tidak ditemukan");
    }
    return ();
}

# Loads the parent proyek or fails with NOT_FOUND. Shared by every operation so a share can never be
# created/read/mutated under a non-existent (or soft-deleted) proyek.
#
# + proyekId - the proyek id to load
# + return - the proyek, a NOT_FOUND AppError if it doesn't exist, or an error
function requireProyek(int proyekId) returns models:Proyek|error {
    models:Proyek? proyek = check repositories:findProyekById(proyekId);
    if proyek is () {
        return utils:notFoundError("Proyek dengan id " + proyekId.toString() + " tidak ditemukan");
    }
    return proyek;
}

# Validates nilai_share (> 0) and the optional persentase (0..100).
#
# + nilaiShare - the absolute value allotted
# + persentase - the optional percentage
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateUnitShareValue(decimal nilaiShare, decimal? persentase) returns models:AppError? {
    if nilaiShare <= 0d {
        return utils:validationError("Nilai share harus lebih besar dari 0");
    }
    if persentase is decimal && (persentase < 0d || persentase > 100d) {
        return utils:validationError("Persentase harus di antara 0 dan 100");
    }
    return ();
}

# Fails with VALIDATION_ERROR if the referenced unit doesn't exist (or is inactive).
#
# + unitId - the unit id to check
# + return - a VALIDATION_ERROR AppError if missing, () if ok, or an error
function ensureUnitExists(int unitId) returns models:AppError|error? {
    boolean ok = check repositories:unitExistsActive(unitId);
    if !ok {
        return utils:validationError("Unit tidak ditemukan");
    }
    return ();
}

# Fails with VALIDATION_ERROR if adding `nilaiShare` would push the proyek's total share (excluding
# `excludeId`) past its `nilai_proyek` — the unit_share rows split the project's value, they must not
# over-allocate it.
#
# + proyekId - the proyek id
# + nilaiShare - the share value being added/updated
# + nilaiProyek - the proyek's total value (ceiling)
# + excludeId - a share id to exclude from the running total (0 on insert; target id on update)
# + return - a VALIDATION_ERROR AppError if it would over-allocate, () if ok, or an error
function ensureShareTotalFits(int proyekId, decimal nilaiShare, decimal nilaiProyek, int excludeId)
        returns models:AppError|error? {
    decimal existingTotal = check repositories:sumUnitShare(proyekId, excludeId);
    if existingTotal + nilaiShare > nilaiProyek {
        return utils:validationError("Total unit share melebihi nilai proyek (" + nilaiProyek.toString() + ")");
    }
    return ();
}
