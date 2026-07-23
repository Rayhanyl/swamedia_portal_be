import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Target Revenue Unit service =====
#
# Business rules and validation for target_revenue_unit CRUD. Domain failures are `models:AppError`;
# infrastructure failures propagate as plain `error`. `tahun` validation reuses `validateProyekTahun`
# from proyek_service (same `services` module). Each (unit, tahun) pair is unique; deletes are
# physical (the table has no soft-delete column).

# Lists target rows with optional filters and pagination.
#
# + search - optional case-insensitive filter on the unit name
# + unitId - optional exact unit_id filter
# + tahun - optional exact tahun filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, or an error
public function getTargetRevenueUnit(string? search, int? unitId, int? tahun, int page, int 'limit)
        returns models:TargetRevenueUnitListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:TargetRevenueUnit[] items; int totalItems;|} result =
        check repositories:findTargetRevenueUnit(search, unitId, tahun, safeLimit, offset);

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

# Fetches a single target row by id.
#
# + id - the target_revenue_unit id
# + return - the row, a NOT_FOUND AppError if it does not exist, or an error
public function getTargetRevenueUnitById(int id) returns models:TargetRevenueUnit|error {
    models:TargetRevenueUnit? row = check repositories:findTargetRevenueUnitById(id);
    if row is () {
        return utils:notFoundError("Target revenue unit dengan id " + id.toString() + " tidak ditemukan");
    }
    return row;
}

# Creates a target row: validates the unit, year, and non-negative quarter targets, and rejects a
# duplicate (unit, tahun).
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created row, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createTargetRevenueUnit(models:TargetRevenueUnitCreateRequest payload, string subject, string? ipAddress = ())
        returns models:TargetRevenueUnit|error {
    check validateProyekTahun(payload.tahun);
    decimal tw1 = payload?.targetTw1 ?: 0d;
    decimal tw2 = payload?.targetTw2 ?: 0d;
    decimal tw3 = payload?.targetTw3 ?: 0d;
    decimal tw4 = payload?.targetTw4 ?: 0d;
    check validateTargets(tw1, tw2, tw3, tw4);

    boolean unitOk = check repositories:unitExistsActive(payload.unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    boolean dup = check repositories:targetRevenueUnitExists(payload.unitId, payload.tahun, 0);
    if dup {
        return utils:conflictError("Target revenue untuk unit dan tahun tersebut sudah ada");
    }

    models:TargetRevenueUnit created = check repositories:insertTargetRevenueUnit(payload.unitId, payload.tahun,
            tw1, tw2, tw3, tw4, subject);
    logAudit("target_revenue_unit", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates a target row. Same validations as create; the row being updated is excluded from the
# duplicate check.
#
# + id - the target_revenue_unit id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated row, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateTargetRevenueUnit(int id, models:TargetRevenueUnitUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:TargetRevenueUnit|error {
    check validateProyekTahun(payload.tahun);
    decimal tw1 = payload?.targetTw1 ?: 0d;
    decimal tw2 = payload?.targetTw2 ?: 0d;
    decimal tw3 = payload?.targetTw3 ?: 0d;
    decimal tw4 = payload?.targetTw4 ?: 0d;
    check validateTargets(tw1, tw2, tw3, tw4);

    models:TargetRevenueUnit? existing = check repositories:findTargetRevenueUnitById(id);
    if existing is () {
        return utils:notFoundError("Target revenue unit dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean unitOk = check repositories:unitExistsActive(payload.unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    boolean dup = check repositories:targetRevenueUnitExists(payload.unitId, payload.tahun, id);
    if dup {
        return utils:conflictError("Target revenue untuk unit dan tahun tersebut sudah ada");
    }

    models:TargetRevenueUnit? updated = check repositories:updateTargetRevenueUnit(
            id, payload.unitId, payload.tahun, tw1, tw2, tw3, tw4, subject);
    if updated is () {
        return utils:notFoundError("Target revenue unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("target_revenue_unit", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Deletes a target row (physical delete — the table has no soft-delete column).
#
# + id - the target_revenue_unit id to delete
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - (), a NOT_FOUND AppError, or an error
public function deleteTargetRevenueUnit(int id, string subject, string? ipAddress = ()) returns error? {
    // Read the row before deleting purely so the audit entry can record what was removed.
    models:TargetRevenueUnit? existing = check repositories:findTargetRevenueUnitById(id);
    boolean deleted = check repositories:deleteTargetRevenueUnit(id);
    if !deleted {
        return utils:notFoundError("Target revenue unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("target_revenue_unit", id.toString(), "DELETE", existing is () ? () : existing.toJson(), (), subject, ipAddress);
    return ();
}

# Validates the four quarter targets: each must be non-negative.
#
# + tw1 - quarter-1 target
# + tw2 - quarter-2 target
# + tw3 - quarter-3 target
# + tw4 - quarter-4 target
# + return - a VALIDATION_ERROR AppError if any is negative, else ()
function validateTargets(decimal tw1, decimal tw2, decimal tw3, decimal tw4) returns models:AppError? {
    if tw1 < 0d || tw2 < 0d || tw3 < 0d || tw4 < 0d {
        return utils:validationError("Target tiap triwulan tidak boleh negatif");
    }
    return ();
}
