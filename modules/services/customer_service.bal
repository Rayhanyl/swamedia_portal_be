import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Customer service =====
#
# Business rules for customer. Depends on the karyawan (am_id) and industri (industri_id)
# masters. Domain failures are `models:AppError`; infrastructure failures propagate as `error`.
#
# status_peluang enum confirmed with the product owner: PROSPEK / NEGOSIASI / DEAL / BATAL.

# Lists non-deleted customers (list projection) with optional filters and pagination.
#
# + search - optional case-insensitive filter on nama
# + amId - optional exact am_id filter
# + industriId - optional exact industri_id filter
# + statusPeluang - optional exact status_peluang filter
# + jenisCustomer - optional exact jenis_customer filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of customers plus pagination metadata, or an error
public function getCustomers(string? search, int? amId, int? industriId, string? statusPeluang,
        string? jenisCustomer, int page, int 'limit) returns models:CustomerListResult|error {
    if statusPeluang is string && statusPeluang.trim().length() > 0 && !isValidStatusPeluang(statusPeluang) {
        return utils:validationError("status_peluang harus salah satu dari PROSPEK, NEGOSIASI, DEAL, BATAL");
    }
    if jenisCustomer is string && jenisCustomer.trim().length() > 0 && !isValidJenisCustomer(jenisCustomer) {
        return utils:validationError("jenis_customer harus salah satu dari ENTERPRISE, BANKING, BUMN, GOVERNMENT");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Customer[] items; int totalItems;|} result =
        check repositories:findCustomers(search, amId, industriId, statusPeluang, jenisCustomer, safeLimit, offset);

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

# Fetches a single customer (detail projection with amNama/industriNama) by id.
#
# + id - the customer id
# + return - the customer detail, or a NOT_FOUND AppError if it does not exist, or an error
public function getCustomerById(int id) returns models:CustomerDetail|error {
    models:CustomerDetail? customer = check repositories:findCustomerById(id);
    if customer is () {
        return utils:notFoundError("Customer dengan id " + id.toString() + " tidak ditemukan");
    }
    return customer;
}

# Creates a new customer after validating name, status_peluang and the am/industri references,
# then returns the freshly joined detail.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created customer detail, a VALIDATION_ERROR AppError, or an error
public function createCustomer(models:CustomerCreateRequest payload, string subject, string? ipAddress = ())
        returns models:CustomerDetail|error {
    string nama = payload.nama.trim();
    check validateCustomerNama(nama);

    string statusPeluang = payload?.statusPeluang ?: "PROSPEK";
    if !isValidStatusPeluang(statusPeluang) {
        return utils:validationError("status_peluang harus salah satu dari PROSPEK, NEGOSIASI, DEAL, BATAL");
    }

    int? amId = payload?.amId;
    check validateCustomerAm(amId);
    int? industriId = payload?.industriId;
    check validateCustomerIndustri(industriId);

    string? jenisCustomer = trimToNil(payload?.jenisCustomer);
    if jenisCustomer is string && !isValidJenisCustomer(jenisCustomer) {
        return utils:validationError("jenis_customer harus salah satu dari ENTERPRISE, BANKING, BUMN, GOVERNMENT");
    }

    int newId = check repositories:insertCustomer(nama, amId, industriId, statusPeluang, jenisCustomer, subject);

    models:CustomerDetail? created = check repositories:findCustomerById(newId);
    if created is () {
        return error("Customer created (id " + newId.toString() + ") but could not be read back");
    }
    logAudit("customer", newId.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates an existing customer, then returns the freshly joined detail.
#
# + id - the customer id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated customer detail, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updateCustomer(int id, models:CustomerUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:CustomerDetail|error {
    string nama = payload.nama.trim();
    check validateCustomerNama(nama);

    if !isValidStatusPeluang(payload.statusPeluang) {
        return utils:validationError("status_peluang harus salah satu dari PROSPEK, NEGOSIASI, DEAL, BATAL");
    }

    int? amId = payload?.amId;
    check validateCustomerAm(amId);
    int? industriId = payload?.industriId;
    check validateCustomerIndustri(industriId);

    string? jenisCustomer = trimToNil(payload?.jenisCustomer);
    if jenisCustomer is string && !isValidJenisCustomer(jenisCustomer) {
        return utils:validationError("jenis_customer harus salah satu dari ENTERPRISE, BANKING, BUMN, GOVERNMENT");
    }

    models:CustomerDetail? existing = check repositories:findCustomerById(id);
    if existing is () {
        return utils:notFoundError("Customer dengan id " + id.toString() + " tidak ditemukan");
    }

    int? updatedId = check repositories:updateCustomer(id, nama, amId, industriId,
            payload.statusPeluang, jenisCustomer, subject);
    if updatedId is () {
        return utils:notFoundError("Customer dengan id " + id.toString() + " tidak ditemukan");
    }

    models:CustomerDetail? updated = check repositories:findCustomerById(id);
    if updated is () {
        return utils:notFoundError("Customer dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("customer", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Soft-deletes a customer after ensuring it exists and has no active dependent rows.
#
# + id - the customer id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteCustomer(int id, string subject, string? ipAddress = ()) returns error? {
    models:CustomerDetail? existing = check repositories:findCustomerById(id);
    if existing is () {
        return utils:notFoundError("Customer dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean referenced = check repositories:isCustomerReferenced(id);
    if referenced {
        return utils:conflictError("Customer tidak dapat dihapus karena masih memiliki Proyek/Contact/Kontrak aktif");
    }

    boolean deleted = check repositories:softDeleteCustomer(id, subject);
    if !deleted {
        return utils:notFoundError("Customer dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("customer", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Validates nama: required, 3-150 characters (after trimming).
#
# + nama - the customer name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateCustomerNama(string nama) returns models:AppError? {
    if nama.length() < 3 || nama.length() > 150 {
        return utils:validationError("Nama customer wajib diisi, panjang 3-150 karakter");
    }
    return ();
}

# Ensures the referenced Account Manager (karyawan) exists and is not deleted.
#
# + amId - the optional account manager (karyawan) id to validate
# + return - a VALIDATION_ERROR AppError if not found, () if valid/absent, or an error
function validateCustomerAm(int? amId) returns models:AppError|error? {
    if amId is int {
        boolean ok = check repositories:karyawanExistsActive(amId);
        if !ok {
            return utils:validationError("Account Manager (karyawan) tidak ditemukan");
        }
    }
    return ();
}

# Ensures the referenced industri exists and is not deleted.
#
# + industriId - the optional industri id to validate
# + return - a VALIDATION_ERROR AppError if not found, () if valid/absent, or an error
function validateCustomerIndustri(int? industriId) returns models:AppError|error? {
    if industriId is int {
        boolean ok = check repositories:industriExistsActive(industriId);
        if !ok {
            return utils:validationError("Industri tidak ditemukan");
        }
    }
    return ();
}

function isValidStatusPeluang(string status) returns boolean {
    return status == "PROSPEK" || status == "NEGOSIASI" || status == "DEAL" || status == "BATAL";
}

# jenis_customer enum per DB check constraint `ck_customer_jenis`.
#
# + jenis - the customer type to validate
# + return - true if it is one of the allowed enum values
function isValidJenisCustomer(string jenis) returns boolean {
    return jenis == "ENTERPRISE" || jenis == "BANKING" || jenis == "BUMN" || jenis == "GOVERNMENT";
}
