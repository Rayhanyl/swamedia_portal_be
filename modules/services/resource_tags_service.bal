import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Resource Tags service =====
#
# Business rules and validation for resource tags. Adds a `status` field (AKTIF/TIDAK_AKTIF)
# and an optional `deskripsi` on top of the same (kode, unit_id) uniqueness rules as Tags.

const string RT_STATUS_AKTIF = "AKTIF";
const string RT_STATUS_TIDAK_AKTIF = "TIDAK_AKTIF";

# Lists non-deleted resource tags with optional search/unit/status filters and pagination.
#
# + search - optional case-insensitive filter on kode or nama
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of resource tags plus pagination metadata, or an error
public function getResourceTags(string? search, int? unitId, string? status, int page, int 'limit)
        returns models:ResourceTagsListResult|error {
    if status is string && status.trim().length() > 0 && !isValidRtStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:ResourceTags[] items; int totalItems;|} result =
        check repositories:findResourceTags(search, unitId, status, safeLimit, offset);

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

# Fetches a single resource tag by id.
#
# + id - the resource tag id
# + return - the resource tag, or a NOT_FOUND AppError if it does not exist, or an error
public function getResourceTagsById(int id) returns models:ResourceTags|error {
    models:ResourceTags? tag = check repositories:findResourceTagsById(id);
    if tag is () {
        return utils:notFoundError("Resource Tag dengan id " + id.toString() + " tidak ditemukan");
    }
    return tag;
}

# Creates a new resource tag after validating fields, unit reference, status and uniqueness.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created resource tag, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createResourceTags(models:ResourceTagsCreateRequest payload, string subject)
        returns models:ResourceTags|error {
    string kode = payload.kode.trim();
    check validateRtKode(kode);
    string nama = payload.nama.trim();
    check validateRtNama(nama);

    string status = payload?.status ?: RT_STATUS_AKTIF;
    if !isValidRtStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int? unitId = payload?.unitId;
    check validateRtUnitRef(unitId);

    string? deskripsi = payload?.deskripsi;

    boolean duplicate = check repositories:resourceTagsKodeUnitExists(kode, unitId, 0);
    if duplicate {
        return utils:conflictError("Kombinasi kode dan unit sudah digunakan");
    }

    models:ResourceTags created = check repositories:insertResourceTags(kode, nama, unitId, deskripsi, status, subject);
    logAudit("resource_tags", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates an existing resource tag. Re-checks (kode, unit_id) uniqueness excluding the row itself.
#
# + id - the resource tag id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated resource tag, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateResourceTags(int id, models:ResourceTagsUpdateRequest payload, string subject)
        returns models:ResourceTags|error {
    string kode = payload.kode.trim();
    check validateRtKode(kode);
    string nama = payload.nama.trim();
    check validateRtNama(nama);

    if !isValidRtStatus(payload.status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int? unitId = payload?.unitId;
    check validateRtUnitRef(unitId);

    models:ResourceTags? existing = check repositories:findResourceTagsById(id);
    if existing is () {
        return utils:notFoundError("Resource Tag dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean duplicate = check repositories:resourceTagsKodeUnitExists(kode, unitId, id);
    if duplicate {
        return utils:conflictError("Kombinasi kode dan unit sudah digunakan");
    }

    string? deskripsi = payload?.deskripsi;
    models:ResourceTags? updated =
        check repositories:updateResourceTags(id, kode, nama, unitId, deskripsi, payload.status, subject);
    if updated is () {
        return utils:notFoundError("Resource Tag dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("resource_tags", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Soft-deletes a resource tag after ensuring it exists and is not used by any resource unit or tagihan.
#
# + id - the resource tag id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteResourceTags(int id, string subject) returns error? {
    models:ResourceTags? existing = check repositories:findResourceTagsById(id);
    if existing is () {
        return utils:notFoundError("Resource Tag dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean referenced = check repositories:isResourceTagReferenced(id);
    if referenced {
        return utils:conflictError("Resource Tag masih digunakan oleh Resource Unit/Tagihan");
    }

    boolean deleted = check repositories:softDeleteResourceTags(id, subject);
    if !deleted {
        return utils:notFoundError("Resource Tag dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("resource_tags", id.toString(), "DELETE", existing.toJson(), (), subject);
    return ();
}

# Validates kode: required, 1-20 characters (after trimming).
#
# + kode - the resource tag code to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateRtKode(string kode) returns models:AppError? {
    if kode.length() < 1 || kode.length() > 20 {
        return utils:validationError("Kode resource tag wajib diisi, panjang 1-20 karakter");
    }
    return ();
}

# Validates nama: required, 1-100 characters (after trimming).
#
# + nama - the resource tag name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateRtNama(string nama) returns models:AppError? {
    if nama.length() < 1 || nama.length() > 100 {
        return utils:validationError("Nama resource tag wajib diisi, panjang 1-100 karakter");
    }
    return ();
}

# Ensures the referenced unit (when supplied) exists and is not deleted.
#
# + unitId - the optional unit id to validate
# + return - a VALIDATION_ERROR AppError if not found, () if valid/absent, or an error
function validateRtUnitRef(int? unitId) returns models:AppError|error? {
    if unitId is int {
        boolean unitOk = check repositories:unitExistsActive(unitId);
        if !unitOk {
            return utils:validationError("Unit tidak ditemukan");
        }
    }
    return ();
}

function isValidRtStatus(string status) returns boolean {
    return status == RT_STATUS_AKTIF || status == RT_STATUS_TIDAK_AKTIF;
}
