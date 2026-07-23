import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Target Sales Unit service =====
#
# Business rules and validation for target_sales_unit CRUD — the sales twin of
# target_revenue_unit_service. Domain failures are `models:AppError`; infrastructure failures
# propagate as plain `error`. Reuses the module-scoped `validateProyekTahun` (proyek_service) and
# `validateTargets` (target_revenue_unit_service) helpers rather than redeclaring them. Each
# (unit, tahun) pair is unique; deletes are physical (the table has no soft-delete column).

# Lists target rows with optional filters and pagination.
#
# + search - optional case-insensitive filter on the unit name
# + unitId - optional exact unit_id filter
# + tahun - optional exact tahun filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, or an error
public function getTargetSalesUnit(string? search, int? unitId, int? tahun, int page, int 'limit)
        returns models:TargetSalesUnitListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:TargetSalesUnit[] items; int totalItems;|} result =
        check repositories:findTargetSalesUnit(search, unitId, tahun, safeLimit, offset);

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
# + id - the target_sales_unit id
# + return - the row, a NOT_FOUND AppError if it does not exist, or an error
public function getTargetSalesUnitById(int id) returns models:TargetSalesUnit|error {
    models:TargetSalesUnit? row = check repositories:findTargetSalesUnitById(id);
    if row is () {
        return utils:notFoundError("Target sales unit dengan id " + id.toString() + " tidak ditemukan");
    }
    return row;
}

# Creates a target row: validates the unit, year, and non-negative quarter targets, and rejects a
# duplicate (unit, tahun).
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created row, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createTargetSalesUnit(models:TargetSalesUnitCreateRequest payload, string subject, string? ipAddress = ())
        returns models:TargetSalesUnit|error {
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
    boolean dup = check repositories:targetSalesUnitExists(payload.unitId, payload.tahun, 0);
    if dup {
        return utils:conflictError("Target sales untuk unit dan tahun tersebut sudah ada");
    }

    models:TargetSalesUnit created = check repositories:insertTargetSalesUnit(payload.unitId, payload.tahun,
            tw1, tw2, tw3, tw4, subject);
    logAudit("target_sales_unit", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates a target row. Same validations as create; the row being updated is excluded from the
# duplicate check.
#
# + id - the target_sales_unit id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated row, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateTargetSalesUnit(int id, models:TargetSalesUnitUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:TargetSalesUnit|error {
    check validateProyekTahun(payload.tahun);
    decimal tw1 = payload?.targetTw1 ?: 0d;
    decimal tw2 = payload?.targetTw2 ?: 0d;
    decimal tw3 = payload?.targetTw3 ?: 0d;
    decimal tw4 = payload?.targetTw4 ?: 0d;
    check validateTargets(tw1, tw2, tw3, tw4);

    models:TargetSalesUnit? existing = check repositories:findTargetSalesUnitById(id);
    if existing is () {
        return utils:notFoundError("Target sales unit dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean unitOk = check repositories:unitExistsActive(payload.unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    boolean dup = check repositories:targetSalesUnitExists(payload.unitId, payload.tahun, id);
    if dup {
        return utils:conflictError("Target sales untuk unit dan tahun tersebut sudah ada");
    }

    models:TargetSalesUnit? updated = check repositories:updateTargetSalesUnit(
            id, payload.unitId, payload.tahun, tw1, tw2, tw3, tw4, subject);
    if updated is () {
        return utils:notFoundError("Target sales unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("target_sales_unit", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Deletes a target row (physical delete — the table has no soft-delete column).
#
# + id - the target_sales_unit id to delete
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - (), a NOT_FOUND AppError, or an error
public function deleteTargetSalesUnit(int id, string subject, string? ipAddress = ()) returns error? {
    // Read the row before deleting purely so the audit entry can record what was removed.
    models:TargetSalesUnit? existing = check repositories:findTargetSalesUnitById(id);
    boolean deleted = check repositories:deleteTargetSalesUnit(id);
    if !deleted {
        return utils:notFoundError("Target sales unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("target_sales_unit", id.toString(), "DELETE", existing is () ? () : existing.toJson(), (), subject, ipAddress);
    return ();
}
