import ballerina/log;
import ballerina/time;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Proyek service =====
#
# Business rules and validation for Proyek. Domain failures are `models:AppError`; infrastructure
# failures propagate as plain `error`.
#
# `kode_proyek` generation mirrors `nomor_surat_service`'s number generation exactly: this layer
# validates inputs and resolves the pieces the repository's atomic insert needs (the unit's
# kode_unit, the sys_config prefix), then delegates the read-MAX/insert race handling to
# `repositories:insertProyek`. `DATE_PATTERN`/`isUniqueViolation`/`isLockTimeout` are reused
# directly from `nomor_surat_service` (same `services` module, already generic — no need to
# redeclare them here).
#
# Status changes (including the initial status at creation) always write a `log_status` row and,
# on first transition into "DEAL_KONTRAK", auto-set `tanggal_deal` — both handled entirely inside
# `repositories:insertProyek`/`updateProyek` per schema implementation note #1.

final string[] PROYEK_VALID_STATUS = [
    "INFO_PELUANG", "UNDANGAN_PENJELASAN", "MEETING_INISIASI", "PROSES_PROPOSAL",
    "EVALUASI_ADMIN_TEKNIS", "DEAL_KONTRAK", "GAGAL"
];

const string PROYEK_STATUS_DEFAULT = "INFO_PELUANG";
const int PROYEK_TAHUN_MIN = 2000;
const int PROYEK_TAHUN_MAX = 2100;

# The only units a proyek may be assigned to: Service Delivery, Strategic Enablement, Billing
# System Solutions, Digital Ecosystem Solutions, Product Operational Support. Deliberately
# excludes structural/parent units (e.g. Strategic Enterprise Solution, whose revenue is just the
# combined total of its Service Delivery + Strategic Enablement children) and non-delivery units
# (Marketing & Sales, Human Capital, Finance). Must be kept in sync with the `kode_unit IN (...)`
# list in `repositories:findProyekEligibleUnits`.
final string[] PROYEK_ELIGIBLE_UNIT_CODES = ["SD", "SE", "BILL", "DES", "POS"];

# Lists non-deleted proyek with optional filters and pagination.
#
# + search - optional case-insensitive filter on kode_proyek or nama_proyek
# + customerId - optional exact customer_id filter
# + industriId - optional exact industri_id filter
# + unitId - optional exact unit_id filter
# + picSalesId - optional exact pic_sales_id filter
# + status - optional exact status filter
# + tahun - optional exact tahun filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of proyek plus pagination metadata, a VALIDATION_ERROR AppError, or an error
public function getProyek(string? search, int? customerId, int? industriId, int? unitId, int? picSalesId,
        string? status, int? tahun, int page, int 'limit) returns models:ProyekListResult|error {
    if status is string && status.trim().length() > 0 && !isValidProyekStatus(status) {
        return utils:validationError("Status proyek tidak valid");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Proyek[] items; int totalItems;|} result = check repositories:findProyek(
            search, customerId, industriId, unitId, picSalesId, status, tahun, safeLimit, offset);

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

# Fetches a single proyek by id.
#
# + id - the proyek id
# + return - the proyek, or a NOT_FOUND AppError if it does not exist, or an error
public function getProyekById(int id) returns models:Proyek|error {
    models:Proyek? proyek = check repositories:findProyekById(id);
    if proyek is () {
        return utils:notFoundError("Proyek dengan id " + id.toString() + " tidak ditemukan");
    }
    return proyek;
}

# Fetches the status-transition history of a proyek.
#
# + id - the proyek id
# + return - the log_status rows (newest first), a NOT_FOUND AppError if the proyek doesn't exist, or an error
public function getProyekLogStatus(int id) returns models:ProyekLogStatus[]|error {
    models:Proyek? proyek = check repositories:findProyekById(id);
    if proyek is () {
        return utils:notFoundError("Proyek dengan id " + id.toString() + " tidak ditemukan");
    }
    return repositories:findProyekLogStatus(id);
}

# Creates a new proyek: validates inputs and every FK reference, resolves the pieces needed for
# kode_proyek generation (unit's kode_unit + sys_config prefix), then delegates the atomic
# generate + insert (+ initial log_status row) to the repository.
#
# + payload - the create request body (kodeProyek is computed here, never taken from it)
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created proyek detail, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createProyek(models:ProyekCreateRequest payload, string subject, string? ipAddress = ()) returns models:Proyek|error {
    string namaProyek = payload.namaProyek.trim();
    check validateNamaProyek(namaProyek);
    string? departemen = check normalizeProyekField(payload?.departemen, 100, "Departemen");
    string? noKontrak = check normalizeProyekField(payload?.noKontrak, 100, "No kontrak");

    decimal nilaiProyek = payload.nilaiProyek;
    decimal subkon = payload?.subkon ?: 0d;
    check validateNilaiProyek(nilaiProyek, subkon);

    string status = payload?.status ?: PROYEK_STATUS_DEFAULT;
    if !isValidProyekStatus(status) {
        return utils:validationError("Status proyek tidak valid");
    }

    string? tanggalKontrak = check validateProyekDate(payload?.tanggalKontrak, "Tanggal kontrak");
    string? tanggalBast = check validateProyekDate(payload?.tanggalBast, "Tanggal BAST");
    string? tanggalMulai = check validateProyekDate(payload?.tanggalMulai, "Tanggal mulai");
    string? targetSelesai = check validateProyekDate(payload?.targetSelesai, "Target selesai");
    string? keteranganPembayaran = normalizeProyekText(payload?.keteranganPembayaran);

    int tahun = payload?.tahun ?: currentProyekYear();
    check validateProyekTahun(tahun);

    boolean customerOk = check repositories:customerExistsActive(payload.customerId);
    if !customerOk {
        return utils:validationError("Customer tidak ditemukan");
    }
    boolean industriOk = check repositories:industriExistsActive(payload.industriId);
    if !industriOk {
        return utils:validationError("Industri tidak ditemukan");
    }
    models:Unit? unit = check repositories:findUnitById(payload.unitId);
    if unit is () {
        return utils:validationError("Unit tidak ditemukan");
    }
    if PROYEK_ELIGIBLE_UNIT_CODES.indexOf(unit.kodeUnit) is () {
        return utils:validationError(
                "Unit '" + unit.namaUnit + "' tidak berhak menerima proyek — pilih salah satu dari " +
                "Service Delivery, Strategic Enablement, Billing System Solutions, Digital Ecosystem " +
                "Solutions, atau Product Operational Support");
    }
    boolean picSalesOk = check repositories:karyawanExistsActive(payload.picSalesId);
    if !picSalesOk {
        return utils:validationError("PIC Sales (karyawan) tidak ditemukan");
    }
    int? pmoId = payload?.pmoId;
    if pmoId is int {
        boolean pmoOk = check repositories:karyawanExistsActive(pmoId);
        if !pmoOk {
            return utils:validationError("PMO (karyawan) tidak ditemukan");
        }
    }

    int? kontrakPayungId = payload?.kontrakPayungId;
    if kontrakPayungId is int {
        check ensureKontrakPayungBelongsToCustomer(kontrakPayungId, payload.customerId);
    }
    int? kontrakBiasaId = payload?.kontrakBiasaId;
    if kontrakBiasaId is int {
        check ensureKontrakBiasaBelongsToCustomer(kontrakBiasaId, payload.customerId);
    }

    string prefix = check resolveKodeProyekPrefix();

    int|error inserted = repositories:insertProyek(payload.customerId, payload.industriId, payload.unitId,
            unit.kodeUnit, prefix, kontrakPayungId, kontrakBiasaId, namaProyek, departemen, nilaiProyek, subkon,
            payload.picSalesId, pmoId, noKontrak, tanggalKontrak, tanggalBast, tanggalMulai, targetSelesai,
            keteranganPembayaran, status, tahun, subject);
    if inserted is error {
        // Same "try again" race as nomor_surat_service:createNomorSurat — either the advisory
        // lock timed out, or the unique constraint on kode_proyek fired as a last-resort safety
        // net. Either way this is not a server bug.
        if isLockTimeout(inserted) || isUniqueViolation(inserted) {
            return utils:conflictError("Kode proyek sedang diproses oleh request lain, silakan coba lagi");
        }
        return inserted;
    }

    models:Proyek created = check getProyekById(inserted);
    logAudit("proyek", inserted.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates a proyek's mutable fields. `kodeProyek`/`unitId`/`tahun` are never changed — even if the
# client sends them (the open `ProyekUpdateRequest` record silently ignores them). Changing
# `status` writes a `log_status` row and, on first transition into "DEAL_KONTRAK", auto-sets
# `tanggalDeal` — both handled inside `repositories:updateProyek`.
#
# + id - the proyek id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated proyek detail, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updateProyek(int id, models:ProyekUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:Proyek|error {
    string namaProyek = payload.namaProyek.trim();
    check validateNamaProyek(namaProyek);
    string? departemen = check normalizeProyekField(payload?.departemen, 100, "Departemen");
    string? noKontrak = check normalizeProyekField(payload?.noKontrak, 100, "No kontrak");

    decimal nilaiProyek = payload.nilaiProyek;
    decimal subkon = payload.subkon;
    check validateNilaiProyek(nilaiProyek, subkon);

    if !isValidProyekStatus(payload.status) {
        return utils:validationError("Status proyek tidak valid");
    }

    string? tanggalKontrak = check validateProyekDate(payload?.tanggalKontrak, "Tanggal kontrak");
    string? tanggalBast = check validateProyekDate(payload?.tanggalBast, "Tanggal BAST");
    string? tanggalMulai = check validateProyekDate(payload?.tanggalMulai, "Tanggal mulai");
    string? targetSelesai = check validateProyekDate(payload?.targetSelesai, "Target selesai");
    string? keteranganPembayaran = normalizeProyekText(payload?.keteranganPembayaran);

    models:Proyek? existing = check repositories:findProyekById(id);
    if existing is () {
        return utils:notFoundError("Proyek dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean customerOk = check repositories:customerExistsActive(payload.customerId);
    if !customerOk {
        return utils:validationError("Customer tidak ditemukan");
    }
    boolean industriOk = check repositories:industriExistsActive(payload.industriId);
    if !industriOk {
        return utils:validationError("Industri tidak ditemukan");
    }
    boolean picSalesOk = check repositories:karyawanExistsActive(payload.picSalesId);
    if !picSalesOk {
        return utils:validationError("PIC Sales (karyawan) tidak ditemukan");
    }
    int? pmoId = payload?.pmoId;
    if pmoId is int {
        boolean pmoOk = check repositories:karyawanExistsActive(pmoId);
        if !pmoOk {
            return utils:validationError("PMO (karyawan) tidak ditemukan");
        }
    }

    int? kontrakPayungId = payload?.kontrakPayungId;
    if kontrakPayungId is int {
        check ensureKontrakPayungBelongsToCustomer(kontrakPayungId, payload.customerId);
    }
    int? kontrakBiasaId = payload?.kontrakBiasaId;
    if kontrakBiasaId is int {
        check ensureKontrakBiasaBelongsToCustomer(kontrakBiasaId, payload.customerId);
    }

    string? statusKomentar = normalizeProyekText(payload?.statusKomentar);

    boolean updated = check repositories:updateProyek(id, payload.customerId, payload.industriId,
            kontrakPayungId, kontrakBiasaId, namaProyek, departemen, nilaiProyek, subkon, payload.picSalesId,
            pmoId, noKontrak, tanggalKontrak, tanggalBast, tanggalMulai, targetSelesai, keteranganPembayaran,
            payload.status, statusKomentar, subject);
    if !updated {
        return utils:notFoundError("Proyek dengan id " + id.toString() + " tidak ditemukan");
    }

    models:Proyek result = check getProyekById(id);
    logAudit("proyek", id.toString(), "UPDATE", existing.toJson(), result.toJson(), subject, ipAddress);
    return result;
}

# Soft-deletes a proyek.
#
# + id - the proyek id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deleteProyek(int id, string subject, string? ipAddress = ()) returns error? {
    models:Proyek? existing = check repositories:findProyekById(id);
    if existing is () {
        return utils:notFoundError("Proyek dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean deleted = check repositories:softDeleteProyek(id, subject);
    if !deleted {
        return utils:notFoundError("Proyek dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("proyek", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Returns active proyek options for the dropdown, optionally filtered by search.
#
# + search - optional case-insensitive filter on kode_proyek or nama_proyek
# + return - the dropdown options (max 100), or an error
public function getProyekDropdown(string? search) returns models:ProyekDropdownItem[]|error {
    return repositories:getProyekDropdown(search);
}

# Returns the fixed set of units eligible to own a proyek, for the Create Proyek form's Unit
# dropdown (see `PROYEK_ELIGIBLE_UNIT_CODES`).
#
# + return - the eligible units (ordered by nama_unit), or an error
public function getProyekEligibleUnits() returns models:UnitDropdownItem[]|error {
    return repositories:findProyekEligibleUnits();
}

# Validates nama_proyek: required, maximum 200 characters (after trimming).
#
# + namaProyek - the trimmed project name
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateNamaProyek(string namaProyek) returns models:AppError? {
    if namaProyek.length() < 1 || namaProyek.length() > 200 {
        return utils:validationError("Nama proyek wajib diisi, panjang maksimal 200 karakter");
    }
    return ();
}

# Validates nilai_proyek (must be positive) and subkon (non-negative, never more than
# nilai_proyek — nilai_bersih is DB-generated as nilai_proyek - subkon and must not go negative).
#
# + nilaiProyek - the total project value
# + subkon - the subcontractor portion
# + return - a VALIDATION_ERROR AppError if invalid, else ()
function validateNilaiProyek(decimal nilaiProyek, decimal subkon) returns models:AppError? {
    if nilaiProyek <= 0d {
        return utils:validationError("Nilai proyek harus lebih besar dari 0");
    }
    if subkon < 0d {
        return utils:validationError("Subkon tidak boleh negatif");
    }
    if subkon > nilaiProyek {
        return utils:validationError("Subkon tidak boleh melebihi nilai proyek");
    }
    return ();
}

# Validates tahun against the DB's `ck_proyek_tahun` range.
#
# + tahun - the numbering year
# + return - a VALIDATION_ERROR AppError if out of range, else ()
function validateProyekTahun(int tahun) returns models:AppError? {
    if tahun < PROYEK_TAHUN_MIN || tahun > PROYEK_TAHUN_MAX {
        return utils:validationError(
                "Tahun harus di antara " + PROYEK_TAHUN_MIN.toString() + " dan " + PROYEK_TAHUN_MAX.toString());
    }
    return ();
}

function isValidProyekStatus(string status) returns boolean {
    foreach string s in PROYEK_VALID_STATUS {
        if s == status {
            return true;
        }
    }
    return false;
}

# Trims an optional field and normalizes a blank result to (); rejects a value exceeding
# `maxLength` (matches the corresponding DB column width) with a VALIDATION_ERROR.
#
# + value - the optional raw field value
# + maxLength - the maximum allowed length (matches the DB column width)
# + label - the field label used in the validation error message
# + return - the trimmed value, () if nil/blank, or a VALIDATION_ERROR AppError if too long
function normalizeProyekField(string? value, int maxLength, string label) returns string?|models:AppError {
    if value is () {
        return ();
    }
    string trimmed = value.trim();
    if trimmed.length() == 0 {
        return ();
    }
    if trimmed.length() > maxLength {
        return utils:validationError(label + " maksimal " + maxLength.toString() + " karakter");
    }
    return trimmed;
}

# Trims a nullable free-text field (no length limit — backs `text` columns), returning () when
# nil or blank after trimming.
#
# + value - the optional raw free-text value
# + return - the trimmed value, or () when nil/blank
function normalizeProyekText(string? value) returns string? {
    if value is () {
        return ();
    }
    string trimmed = value.trim();
    return trimmed.length() == 0 ? () : trimmed;
}

# Validates an optional date field: format YYYY-MM-DD and actually parseable. Unlike
# nomor_surat_service's validateTanggal, this does NOT reject future dates — target_selesai in
# particular is routinely in the future.
#
# + value - the optional raw date string
# + label - the field label used in the validation error message
# + return - the trimmed date, () if nil/blank, or a VALIDATION_ERROR AppError if invalid
function validateProyekDate(string? value, string label) returns string?|models:AppError {
    if value is () {
        return ();
    }
    string trimmed = value.trim();
    if trimmed.length() == 0 {
        return ();
    }
    if !DATE_PATTERN.isFullMatch(trimmed) {
        return utils:validationError(label + " tidak valid, gunakan format YYYY-MM-DD");
    }
    time:Utc|time:Error parsed = time:utcFromString(trimmed + "T00:00:00Z");
    if parsed is time:Error {
        return utils:validationError(label + " tidak valid");
    }
    return trimmed;
}

# The current calendar year (server time), used as the default `tahun` when the client omits it.
#
# + return - the current calendar year
function currentProyekYear() returns int {
    time:Civil civil = time:utcToCivil(time:utcNow());
    return civil.year;
}

# Resolves the kode_proyek prefix from sys_config. Mirrors nomor_surat_service:resolvePrefix —
# the `prefix_kode_proyek` row is guaranteed to be seeded, so a missing/blank row is a
# configuration bug, not a condition to silently tolerate with a hardcoded fallback.
#
# + return - the configured prefix, or an INTERNAL_ERROR AppError / error when unresolved
function resolveKodeProyekPrefix() returns string|error {
    string? prefix = check repositories:getPrefixKodeProyek();
    if prefix is () || prefix.trim().length() == 0 {
        log:printError("Konfigurasi sys_config.prefix_kode_proyek tidak ditemukan -- modul Sales Unit "
                + "(Proyek) tidak dapat generate kode tanpa konfigurasi ini, periksa seeding database");
        return utils:internalError("Terjadi kesalahan pada server, silakan coba lagi nanti");
    }
    return prefix.trim();
}

# Returns a VALIDATION_ERROR AppError if the kontrak_payung doesn't exist, or doesn't belong to
# the given customer — the DB has no FK enforcing this relationship itself.
#
# + kontrakPayungId - the kontrak payung id to check
# + customerId - the customer the contract must belong to
# + return - a VALIDATION_ERROR AppError on mismatch, () if ok, or an error
function ensureKontrakPayungBelongsToCustomer(int kontrakPayungId, int customerId)
        returns models:AppError|error? {
    int? ownerId = check repositories:kontrakPayungCustomerId(kontrakPayungId);
    if ownerId is () {
        return utils:validationError("Kontrak payung tidak ditemukan");
    }
    if ownerId != customerId {
        return utils:validationError("Kontrak payung tidak dimiliki oleh customer yang dipilih");
    }
    return ();
}

# Same as `ensureKontrakPayungBelongsToCustomer`, for kontrak_biasa.
#
# + kontrakBiasaId - the kontrak biasa id to check
# + customerId - the customer the contract must belong to
# + return - a VALIDATION_ERROR AppError on mismatch, () if ok, or an error
function ensureKontrakBiasaBelongsToCustomer(int kontrakBiasaId, int customerId) returns models:AppError|error? {
    int? ownerId = check repositories:kontrakBiasaCustomerId(kontrakBiasaId);
    if ownerId is () {
        return utils:validationError("Kontrak biasa tidak ditemukan");
    }
    if ownerId != customerId {
        return utils:validationError("Kontrak biasa tidak dimiliki oleh customer yang dipilih");
    }
    return ();
}
