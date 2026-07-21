import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Tags service =====
#
# Business rules and validation for tags, mirroring the Unit/Industri services. Domain
# failures are `models:AppError`; infrastructure failures propagate as plain `error`.

# Lists non-deleted tags with optional search/unit filters and pagination.
#
# + search - optional case-insensitive filter on kode or nama
# + unitId - optional exact unit_id filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of tags plus pagination metadata, or an error
public function getTags(string? search, int? unitId, int page, int 'limit)
        returns models:TagsListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Tags[] items; int totalItems;|} result =
        check repositories:findTags(search, unitId, safeLimit, offset);

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

# Fetches a single tag by id.
#
# + id - the tag id
# + return - the tag, or a NOT_FOUND AppError if it does not exist, or an error
public function getTagsById(int id) returns models:Tags|error {
    models:Tags? tag = check repositories:findTagsById(id);
    if tag is () {
        return utils:notFoundError("Tag dengan id " + id.toString() + " tidak ditemukan");
    }
    return tag;
}

# Creates a new tag after validating fields, the unit reference and the (kode, unit_id) uniqueness.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created tag, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createTags(models:TagsCreateRequest payload, string subject) returns models:Tags|error {
    string kode = payload.kode.trim();
    check validateTagKode(kode);
    string nama = payload.nama.trim();
    check validateTagNama(nama);

    int? unitId = payload?.unitId;
    check validateUnitRef(unitId);

    boolean duplicate = check repositories:tagsKodeUnitExists(kode, unitId, 0);
    if duplicate {
        return utils:conflictError("Kombinasi kode dan unit sudah digunakan");
    }

    models:Tags created = check repositories:insertTags(kode, nama, unitId, subject);
    logAudit("tags", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates an existing tag. Re-checks the (kode, unit_id) uniqueness excluding the row itself.
#
# + id - the tag id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated tag, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateTags(int id, models:TagsUpdateRequest payload, string subject)
        returns models:Tags|error {
    string kode = payload.kode.trim();
    check validateTagKode(kode);
    string nama = payload.nama.trim();
    check validateTagNama(nama);

    int? unitId = payload?.unitId;
    check validateUnitRef(unitId);

    models:Tags? existing = check repositories:findTagsById(id);
    if existing is () {
        return utils:notFoundError("Tag dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean duplicate = check repositories:tagsKodeUnitExists(kode, unitId, id);
    if duplicate {
        return utils:conflictError("Kombinasi kode dan unit sudah digunakan");
    }

    models:Tags? updated = check repositories:updateTags(id, kode, nama, unitId, subject);
    if updated is () {
        return utils:notFoundError("Tag dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("tags", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Soft-deletes a tag after ensuring it exists and is not used by any proyek.
#
# + id - the tag id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteTags(int id, string subject) returns error? {
    models:Tags? existing = check repositories:findTagsById(id);
    if existing is () {
        return utils:notFoundError("Tag dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean referenced = check repositories:isTagReferenced(id);
    if referenced {
        return utils:conflictError("Tag masih digunakan oleh Proyek");
    }

    boolean deleted = check repositories:softDeleteTags(id, subject);
    if !deleted {
        return utils:notFoundError("Tag dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("tags", id.toString(), "DELETE", existing.toJson(), (), subject);
    return ();
}

# Validates kode: required, 1-20 characters (after trimming).
#
# + kode - the tag code to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateTagKode(string kode) returns models:AppError? {
    if kode.length() < 1 || kode.length() > 20 {
        return utils:validationError("Kode tag wajib diisi, panjang 1-20 karakter");
    }
    return ();
}

# Validates nama: required, 1-100 characters (after trimming).
#
# + nama - the tag name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateTagNama(string nama) returns models:AppError? {
    if nama.length() < 1 || nama.length() > 100 {
        return utils:validationError("Nama tag wajib diisi, panjang 1-100 karakter");
    }
    return ();
}

# Ensures the referenced unit (when supplied) exists and is not deleted.
#
# + unitId - the optional unit id to validate
# + return - a VALIDATION_ERROR AppError if not found, () if valid/absent, or an error
function validateUnitRef(int? unitId) returns models:AppError|error? {
    if unitId is int {
        boolean unitOk = check repositories:unitExistsActive(unitId);
        if !unitOk {
            return utils:validationError("Unit tidak ditemukan");
        }
    }
    return ();
}
