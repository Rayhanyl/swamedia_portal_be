import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Industri service =====
#
# Business rules and validation for industri, mirroring the Unit service. Domain failures
# are returned as `models:AppError` (carrying HTTP status + code); infrastructure failures
# propagate as plain `error`. The resource layer distinguishes the two in its `on fail` block.

const int MAX_KODE_LENGTH = 20;

# Lists non-deleted industri rows with an optional search filter and pagination.
#
# + search - optional case-insensitive filter on kode or nama
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of industri plus pagination metadata, or an error
public function getIndustries(string? search, int page, int 'limit)
        returns models:IndustriListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Industri[] items; int totalItems;|} result =
        check repositories:findIndustries(search, safeLimit, offset);

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

# Fetches a single industri by id.
#
# + id - the industri id
# + return - the industri, or a NOT_FOUND AppError if it does not exist, or an error
public function getIndustriById(int id) returns models:Industri|error {
    models:Industri? industri = check repositories:findIndustriById(id);
    if industri is () {
        return utils:notFoundError("Industri dengan id " + id.toString() + " tidak ditemukan");
    }
    return industri;
}

# Creates a new industri. kode is uppercased on save and checked for case-insensitive uniqueness.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created industri, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createIndustri(models:IndustriCreateRequest payload, string subject)
        returns models:Industri|error {
    string kode = payload.kode.trim().toUpperAscii();
    check validateKode(kode);

    string nama = payload.nama.trim();
    check validateNama(nama);

    boolean exists = check repositories:kodeExists(kode, 0);
    if exists {
        return utils:conflictError("Kode industri sudah digunakan");
    }

    return repositories:insertIndustri(kode, nama, subject);
}

# Updates an existing industri. Validates kode/nama and re-checks kode uniqueness (excluding
# the row being updated), so changing kode to one already used by another industri conflicts.
#
# + id - the industri id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated industri, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateIndustri(int id, models:IndustriUpdateRequest payload, string subject)
        returns models:Industri|error {
    string kode = payload.kode.trim().toUpperAscii();
    check validateKode(kode);

    string nama = payload.nama.trim();
    check validateNama(nama);

    models:Industri? existing = check repositories:findIndustriById(id);
    if existing is () {
        return utils:notFoundError("Industri dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean exists = check repositories:kodeExists(kode, id);
    if exists {
        return utils:conflictError("Kode industri sudah digunakan");
    }

    models:Industri? updated = check repositories:updateIndustri(id, kode, nama, subject);
    if updated is () {
        return utils:notFoundError("Industri dengan id " + id.toString() + " tidak ditemukan");
    }
    return updated;
}

# Soft-deletes an industri after ensuring it exists and is not referenced by an active proyek.
#
# + id - the industri id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteIndustri(int id, string subject) returns error? {
    models:Industri? existing = check repositories:findIndustriById(id);
    if existing is () {
        return utils:notFoundError("Industri dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean referenced = check repositories:isIndustriReferenced(id);
    if referenced {
        return utils:conflictError("Industri tidak dapat dihapus karena masih digunakan oleh Customer/Proyek");
    }

    boolean deleted = check repositories:softDeleteIndustri(id, subject);
    if !deleted {
        return utils:notFoundError("Industri dengan id " + id.toString() + " tidak ditemukan");
    }
    return ();
}

# Validates kode: required, maximum 20 characters (checked after trimming/uppercasing).
#
# + kode - the industri code to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateKode(string kode) returns models:AppError? {
    if kode.length() == 0 {
        return utils:validationError("Kode industri wajib diisi");
    }
    if kode.length() > MAX_KODE_LENGTH {
        return utils:validationError("Kode industri maksimal 20 karakter");
    }
    return ();
}

# Validates nama: required, 3-100 characters (after trimming).
#
# + nama - the industri name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateNama(string nama) returns models:AppError? {
    if nama.length() < 3 || nama.length() > 100 {
        return utils:validationError("Nama industri wajib diisi, panjang 3-100 karakter");
    }
    return ();
}
