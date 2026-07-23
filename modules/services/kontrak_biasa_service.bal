import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Kontrak Biasa service =====
#
# Business rules and validation for Kontrak Biasa. Domain failures are `models:AppError`;
# infrastructure failures propagate as plain `error`. Reuses same-module helpers rather than
# redeclaring them: `validateRequiredDate`/`validateNamaKontrak` from kontrak_payung_service,
# `ensureKontrakPayungBelongsToCustomer` from proyek_service, and `isUniqueViolation` from
# nomor_surat_service. A kontrak biasa may be standalone or hang under a kontrak payung — when
# linked, the parent must belong to the same customer.

# Lists non-deleted kontrak biasa with optional filters and pagination.
#
# + search - optional case-insensitive filter on no_kontrak_biasa or nama_kontrak
# + customerId - optional exact customer_id filter
# + kontrakPayungId - optional exact kontrak_payung_id filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, or an error
public function getKontrakBiasa(string? search, int? customerId, int? kontrakPayungId, int page, int 'limit)
        returns models:KontrakBiasaListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:KontrakBiasa[] items; int totalItems;|} result =
        check repositories:findKontrakBiasa(search, customerId, kontrakPayungId, safeLimit, offset);

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

# Fetches a single kontrak biasa by id.
#
# + id - the kontrak biasa id
# + return - the contract, a NOT_FOUND AppError if it does not exist, or an error
public function getKontrakBiasaById(int id) returns models:KontrakBiasa|error {
    models:KontrakBiasa? kontrak = check repositories:findKontrakBiasaById(id);
    if kontrak is () {
        return utils:notFoundError("Kontrak biasa dengan id " + id.toString() + " tidak ditemukan");
    }
    return kontrak;
}

# Creates a kontrak biasa: validates every field + FK reference (including that an optional parent
# kontrak payung belongs to the same customer) and the number's uniqueness.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created contract, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createKontrakBiasa(models:KontrakBiasaCreateRequest payload, string subject, string? ipAddress = ())
        returns models:KontrakBiasa|error {
    string noKontrak = payload.noKontrakBiasa.trim();
    string namaKontrak = payload.namaKontrak.trim();
    check validateNoKontrakBiasa(noKontrak);
    check validateNamaKontrak(namaKontrak);
    string tanggalKontrak = check validateRequiredDate(payload.tanggalKontrak, "Tanggal kontrak");
    check validateNilai(payload?.nilai);

    boolean customerOk = check repositories:customerExistsActive(payload.customerId);
    if !customerOk {
        return utils:validationError("Customer tidak ditemukan");
    }
    int? kontrakPayungId = payload?.kontrakPayungId;
    if kontrakPayungId is int {
        check ensureKontrakPayungBelongsToCustomer(kontrakPayungId, payload.customerId);
    }

    boolean dup = check repositories:kontrakBiasaNoExists(noKontrak, 0);
    if dup {
        return utils:conflictError("No kontrak biasa sudah digunakan");
    }

    models:KontrakBiasa|error created = repositories:insertKontrakBiasa(kontrakPayungId, payload.customerId,
            noKontrak, namaKontrak, tanggalKontrak, payload?.nilai, subject);
    if created is error {
        if isUniqueViolation(created) {
            return utils:conflictError("No kontrak biasa sudah digunakan");
        }
        return created;
    }
    logAudit("kontrak_biasa", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates a kontrak biasa. Full-replace semantics (an omitted optional field clears its column).
#
# + id - the kontrak biasa id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated contract, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateKontrakBiasa(int id, models:KontrakBiasaUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:KontrakBiasa|error {
    string noKontrak = payload.noKontrakBiasa.trim();
    string namaKontrak = payload.namaKontrak.trim();
    check validateNoKontrakBiasa(noKontrak);
    check validateNamaKontrak(namaKontrak);
    string tanggalKontrak = check validateRequiredDate(payload.tanggalKontrak, "Tanggal kontrak");
    check validateNilai(payload?.nilai);

    models:KontrakBiasa? existing = check repositories:findKontrakBiasaById(id);
    if existing is () {
        return utils:notFoundError("Kontrak biasa dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean customerOk = check repositories:customerExistsActive(payload.customerId);
    if !customerOk {
        return utils:validationError("Customer tidak ditemukan");
    }
    int? kontrakPayungId = payload?.kontrakPayungId;
    if kontrakPayungId is int {
        check ensureKontrakPayungBelongsToCustomer(kontrakPayungId, payload.customerId);
    }

    boolean dup = check repositories:kontrakBiasaNoExists(noKontrak, id);
    if dup {
        return utils:conflictError("No kontrak biasa sudah digunakan");
    }

    models:KontrakBiasa?|error updated = repositories:updateKontrakBiasa(id, kontrakPayungId, payload.customerId,
            noKontrak, namaKontrak, tanggalKontrak, payload?.nilai, subject);
    if updated is error {
        if isUniqueViolation(updated) {
            return utils:conflictError("No kontrak biasa sudah digunakan");
        }
        return updated;
    }
    if updated is () {
        return utils:notFoundError("Kontrak biasa dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("kontrak_biasa", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Soft-deletes a kontrak biasa. Refuses (CONFLICT) if any active proyek still references it.
#
# + id - the kontrak biasa id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteKontrakBiasa(int id, string subject, string? ipAddress = ()) returns error? {
    models:KontrakBiasa? existing = check repositories:findKontrakBiasaById(id);
    if existing is () {
        return utils:notFoundError("Kontrak biasa dengan id " + id.toString() + " tidak ditemukan");
    }
    boolean referenced = check repositories:isKontrakBiasaReferenced(id);
    if referenced {
        return utils:conflictError("Kontrak biasa tidak dapat dihapus karena masih dipakai oleh proyek");
    }
    boolean deleted = check repositories:softDeleteKontrakBiasa(id, subject);
    if !deleted {
        return utils:notFoundError("Kontrak biasa dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("kontrak_biasa", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Returns active kontrak biasa options for the Proyek-form dropdown.
#
# + customerId - optional exact customer_id filter
# + search - optional case-insensitive filter on no_kontrak_biasa or nama_kontrak
# + return - the dropdown options (max 100), or an error
public function getKontrakBiasaDropdown(int? customerId, string? search)
        returns models:KontrakBiasaDropdownItem[]|error {
    return repositories:getKontrakBiasaDropdown(customerId, search);
}

# Validates no_kontrak_biasa: required, max 50 characters.
#
# + noKontrak - the trimmed contract number
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateNoKontrakBiasa(string noKontrak) returns models:AppError? {
    if noKontrak.length() < 1 || noKontrak.length() > 50 {
        return utils:validationError("No kontrak biasa wajib diisi, panjang maksimal 50 karakter");
    }
    return ();
}

# Validates the optional nilai: must be > 0 when present.
#
# + nilai - the optional contract value
# + return - a VALIDATION_ERROR AppError if non-positive, else ()
function validateNilai(decimal? nilai) returns models:AppError? {
    if nilai is decimal && nilai <= 0d {
        return utils:validationError("Nilai kontrak harus lebih besar dari 0");
    }
    return ();
}
