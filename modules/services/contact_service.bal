import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Contact service =====
#
# Business rules for contact. Depends on the customer master (customer_id). Domain failures are
# `models:AppError`; infrastructure failures propagate as plain `error`.
#
# NOTE: `tipe_kontak` is the contact's ROLE (UTAMA/AKTIF/PROSPEK), not an active/inactive flag —
# do not conflate it with is_deleted. Reuses `EMAIL_PATTERN` and `trimToNil` from the services
# module (defined in karyawan_service).

# Lists non-deleted contacts with optional customer/search/tipe filters and pagination.
#
# + customerId - optional exact customer_id filter (the most common query)
# + search - optional case-insensitive filter on nama/email/jabatan
# + tipeKontak - optional exact tipe_kontak filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of contacts plus pagination metadata, or an error
public function getContacts(int? customerId, string? search, string? tipeKontak, int page, int 'limit)
        returns models:ContactListResult|error {
    if tipeKontak is string && tipeKontak.trim().length() > 0 && !isValidTipeKontak(tipeKontak) {
        return utils:validationError("tipe_kontak harus UTAMA, AKTIF, atau PROSPEK");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Contact[] items; int totalItems;|} result =
        check repositories:findContacts(customerId, search, tipeKontak, safeLimit, offset);

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

# Fetches a single contact by id.
#
# + id - the contact id
# + return - the contact, or a NOT_FOUND AppError if it does not exist, or an error
public function getContactById(int id) returns models:Contact|error {
    models:Contact? contact = check repositories:findContactById(id);
    if contact is () {
        return utils:notFoundError("Contact dengan id " + id.toString() + " tidak ditemukan");
    }
    return contact;
}

# Creates a new contact after validating the customer reference and all fields.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created contact, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createContact(models:ContactCreateRequest payload, string subject, string? ipAddress = ())
        returns models:Contact|error {
    check validateCustomerRef(payload.customerId);

    string nama = payload.nama.trim();
    check validateContactNama(nama);

    string? jabatan = trimToNil(payload?.jabatan);
    check validateContactJabatan(jabatan);

    string? email = trimToNil(payload?.email);
    check validateContactEmail(email);

    string? telepon = trimToNil(payload?.telepon);
    check validateTelepon(telepon);

    string tipeKontak = payload?.tipeKontak ?: "AKTIF";
    if !isValidTipeKontak(tipeKontak) {
        return utils:validationError("tipe_kontak harus UTAMA, AKTIF, atau PROSPEK");
    }

    if email is string {
        check ensureEmailAvailable(payload.customerId, email, 0);
    }

    models:Contact created = check repositories:insertContact(payload.customerId, nama, jabatan, email, telepon, tipeKontak, subject);
    logAudit("contact", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates an existing contact. Re-checks the (customer_id, email) uniqueness excluding itself.
#
# + id - the contact id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated contact, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateContact(int id, models:ContactUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:Contact|error {
    check validateCustomerRef(payload.customerId);

    string nama = payload.nama.trim();
    check validateContactNama(nama);

    string? jabatan = trimToNil(payload?.jabatan);
    check validateContactJabatan(jabatan);

    string? email = trimToNil(payload?.email);
    check validateContactEmail(email);

    string? telepon = trimToNil(payload?.telepon);
    check validateTelepon(telepon);

    if !isValidTipeKontak(payload.tipeKontak) {
        return utils:validationError("tipe_kontak harus UTAMA, AKTIF, atau PROSPEK");
    }

    models:Contact? existing = check repositories:findContactById(id);
    if existing is () {
        return utils:notFoundError("Contact dengan id " + id.toString() + " tidak ditemukan");
    }

    if email is string {
        check ensureEmailAvailable(payload.customerId, email, id);
    }

    models:Contact? updated = check repositories:updateContact(id, payload.customerId, nama, jabatan,
            email, telepon, payload.tipeKontak, subject);
    if updated is () {
        return utils:notFoundError("Contact dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("contact", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Soft-deletes a contact after ensuring it exists. Contact has no child tables, so there is no
# dependency check.
#
# + id - the contact id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deleteContact(int id, string subject, string? ipAddress = ()) returns error? {
    models:Contact? existing = check repositories:findContactById(id);
    if existing is () {
        return utils:notFoundError("Contact dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean deleted = check repositories:softDeleteContact(id, subject);
    if !deleted {
        return utils:notFoundError("Contact dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("contact", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Ensures the referenced customer exists and is not deleted.
#
# + customerId - the customer id to validate
# + return - a VALIDATION_ERROR AppError if not found, () if valid, or an error
function validateCustomerRef(int customerId) returns models:AppError|error? {
    boolean ok = check repositories:customerExistsActive(customerId);
    if !ok {
        return utils:validationError("Customer tidak ditemukan");
    }
    return ();
}

# Validates nama: required, 1-100 characters (after trimming).
#
# + nama - the contact name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateContactNama(string nama) returns models:AppError? {
    if nama.length() < 1 || nama.length() > 100 {
        return utils:validationError("Nama contact wajib diisi, panjang 1-100 karakter");
    }
    return ();
}

# Validates jabatan (optional): maximum 100 characters.
#
# + jabatan - the optional job title to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid/absent
function validateContactJabatan(string? jabatan) returns models:AppError? {
    if jabatan is string && jabatan.length() > 100 {
        return utils:validationError("Jabatan maksimal 100 karakter");
    }
    return ();
}

# Validates email (optional): must look like a valid email address.
#
# + email - the optional email to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid/absent
function validateContactEmail(string? email) returns models:AppError? {
    if email is string && !EMAIL_PATTERN.isFullMatch(email) {
        return utils:validationError("Format email tidak valid");
    }
    return ();
}

# Validates telepon (optional): digits, spaces, +, -, () only, max 30 characters.
#
# + telepon - the optional phone number to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid/absent
function validateTelepon(string? telepon) returns models:AppError? {
    if telepon is () {
        return ();
    }
    if telepon.length() > 30 {
        return utils:validationError("Telepon maksimal 30 karakter");
    }
    if !(re `[0-9 +()-]+`).isFullMatch(telepon) {
        return utils:validationError("Format telepon tidak valid");
    }
    return ();
}

# Returns a CONFLICT AppError if (customer_id, email) is already used by another contact.
#
# + customerId - the owning customer id
# + email - the email to check
# + excludeId - a contact id to exclude from the check (0 = none)
# + return - a CONFLICT AppError if taken, () if available, or an error
function ensureEmailAvailable(int customerId, string email, int excludeId) returns models:AppError|error? {
    boolean exists = check repositories:contactEmailExists(customerId, email, excludeId);
    if exists {
        return utils:conflictError("Email sudah digunakan oleh contact lain pada customer ini");
    }
    return ();
}

function isValidTipeKontak(string tipeKontak) returns boolean {
    return tipeKontak == "UTAMA" || tipeKontak == "AKTIF" || tipeKontak == "PROSPEK";
}
