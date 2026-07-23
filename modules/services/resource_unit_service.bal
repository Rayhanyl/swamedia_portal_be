import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Resource Unit service =====
#
# CRUD business rules for resource_unit (headcount/capacity per unit; one row per unit). Domain
# failures are `models:AppError`; infrastructure failures propagate as plain `error`. Validates the
# unit reference, the optional lead karyawan, headcount (>= 0), used-capacity (0..100), and enforces
# one active resource row per unit.

# Lists resource rows with optional filters and pagination.
#
# + search - optional case-insensitive filter on the unit name
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, a VALIDATION_ERROR AppError, or an error
public function getResourceUnit(string? search, int? unitId, string? status, int page, int 'limit)
        returns models:ResourceUnitListResult|error {
    if status is string && status.trim().length() > 0 && !isValidResourceUnitStatus(status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:ResourceUnit[] items; int totalItems;|} result =
        check repositories:findResourceUnit(search, unitId, status, safeLimit, offset);

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

# Fetches a single resource row by id.
#
# + id - the resource_unit id
# + return - the row, a NOT_FOUND AppError if it does not exist, or an error
public function getResourceUnitById(int id) returns models:ResourceUnit|error {
    models:ResourceUnit? row = check repositories:findResourceUnitById(id);
    if row is () {
        return utils:notFoundError("Resource unit dengan id " + id.toString() + " tidak ditemukan");
    }
    return row;
}

# Creates a resource row: validates fields + references and rejects a second row for the same unit.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created row, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createResourceUnit(models:ResourceUnitCreateRequest payload, string subject, string? ipAddress = ())
        returns models:ResourceUnit|error {
    int jumlah = payload?.jumlah ?: 0;
    decimal kapasitas = payload?.kapasitasTerpakai ?: 0d;
    check validateResourceUnitFields(jumlah, kapasitas);

    string status = payload?.status ?: "AKTIF";
    if !isValidResourceUnitStatus(status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    boolean unitOk = check repositories:unitExistsActive(payload.unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    int? leadId = check validateLead(payload?.leadId);

    boolean dup = check repositories:resourceUnitExistsForUnit(payload.unitId, 0);
    if dup {
        return utils:conflictError("Unit ini sudah memiliki data resource unit");
    }

    models:ResourceUnit created = check repositories:insertResourceUnit(payload.unitId, leadId, jumlah, kapasitas, status, subject);
    logAudit("resource_unit", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates a resource row. Same validations as create; the row being updated is excluded from the
# per-unit uniqueness check.
#
# + id - the resource_unit id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated row, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateResourceUnit(int id, models:ResourceUnitUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:ResourceUnit|error {
    int jumlah = payload?.jumlah ?: 0;
    decimal kapasitas = payload?.kapasitasTerpakai ?: 0d;
    check validateResourceUnitFields(jumlah, kapasitas);

    if !isValidResourceUnitStatus(payload.status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    models:ResourceUnit? existing = check repositories:findResourceUnitById(id);
    if existing is () {
        return utils:notFoundError("Resource unit dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean unitOk = check repositories:unitExistsActive(payload.unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    int? leadId = check validateLead(payload?.leadId);

    boolean dup = check repositories:resourceUnitExistsForUnit(payload.unitId, id);
    if dup {
        return utils:conflictError("Unit ini sudah memiliki data resource unit");
    }

    models:ResourceUnit? updated = check repositories:updateResourceUnit(
            id, payload.unitId, leadId, jumlah, kapasitas, payload.status, subject);
    if updated is () {
        return utils:notFoundError("Resource unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("resource_unit", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Soft-deletes a resource row.
#
# + id - the resource_unit id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deleteResourceUnit(int id, string subject, string? ipAddress = ()) returns error? {
    models:ResourceUnit? existing = check repositories:findResourceUnitById(id);
    if existing is () {
        return utils:notFoundError("Resource unit dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean deleted = check repositories:softDeleteResourceUnit(id, subject);
    if !deleted {
        return utils:notFoundError("Resource unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("resource_unit", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Validates headcount (>= 0) and used-capacity (0..100).
#
# + jumlah - the headcount
# + kapasitasTerpakai - the used-capacity percentage
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateResourceUnitFields(int jumlah, decimal kapasitasTerpakai) returns models:AppError? {
    if jumlah < 0 {
        return utils:validationError("Jumlah tidak boleh negatif");
    }
    if kapasitasTerpakai < 0d || kapasitasTerpakai > 100d {
        return utils:validationError("Kapasitas terpakai harus di antara 0 dan 100");
    }
    return ();
}

# Validates the optional lead karyawan: when present, it must be an existing active karyawan.
#
# + leadId - the optional lead karyawan id
# + return - the normalized lead id (() when absent), a VALIDATION_ERROR AppError, or an error
function validateLead(int? leadId) returns int?|error {
    if leadId is () {
        return ();
    }
    boolean ok = check repositories:karyawanExistsActive(leadId);
    if !ok {
        return utils:validationError("Lead (karyawan) tidak ditemukan");
    }
    return leadId;
}

# Validates a resource unit status value.
#
# + status - the status to check
# + return - true if AKTIF / TIDAK_AKTIF
function isValidResourceUnitStatus(string status) returns boolean {
    return status == "AKTIF" || status == "TIDAK_AKTIF";
}
