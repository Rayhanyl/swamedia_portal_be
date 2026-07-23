import ballerina/lang.regexp;
import ballerina/log;
import ballerina/time;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Karyawan service =====
#
# Business rules for karyawan, the most-referenced master (customer.am_id, proyek.pic_sales_id/
# pmo_id, team_member.karyawan_id, resource_unit.lead_id all FK to karyawan.id). Domain failures
# are `models:AppError`; infrastructure failures propagate as plain `error`.
#
# SECURITY NOTE (subject_id): `subject_id` links a karyawan record to a real WSO2 IS identity.
# Even though the UI now edits it in the ordinary Add/Edit form (the separate link-subject
# endpoint was cancelled), it stays sensitive: setting it wrong re-points an IS identity at the
# wrong person. We therefore (1) uniqueness-check it manually here (see `resolveSubjectId`) and
# (2) never expose it in list responses (KaryawanListItem has no subjectId). FUTURE: this module
# should be restricted to the Admin role — role-based authorization does NOT exist at this layer
# yet; that is a separate architectural decision. Do NOT add an ad-hoc role check here.

# Simple email format check (not RFC-complete, just a sane guard): local@domain.tld.
final regexp:RegExp EMAIL_PATTERN = re `[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`;

# Lists non-deleted karyawan (list projection, no subject_id) with optional filters and pagination.
#
# + search - optional case-insensitive filter on nik/nama/email
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of karyawan plus pagination metadata, or an error
public function getKaryawan(string? search, int? unitId, string? status, int page, int 'limit)
        returns models:KaryawanListResult|error {
    if status is string && status.trim().length() > 0 && !isValidKaryawanStatus(status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:KaryawanListItem[] items; int totalItems;|} result =
        check repositories:findKaryawan(search, unitId, status, safeLimit, offset);

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

# Fetches a single karyawan (detail projection, includes subject_id) by id.
#
# + id - the karyawan id
# + return - the karyawan detail, or a NOT_FOUND AppError if it does not exist, or an error
public function getKaryawanById(int id) returns models:KaryawanDetail|error {
    models:KaryawanDetail? karyawan = check repositories:findKaryawanById(id);
    if karyawan is () {
        return utils:notFoundError("Karyawan dengan id " + id.toString() + " tidak ditemukan");
    }
    return karyawan;
}

# Creates a new karyawan after validating all fields, the unit reference, and the uniqueness of
# nik, email and (when supplied) subject_id.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created karyawan detail, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createKaryawan(models:KaryawanCreateRequest payload, string subject, string? ipAddress = ())
        returns models:KaryawanDetail|error {
    string nik = payload.nik.trim();
    string nama = payload.nama.trim();
    string email = payload.email.trim().toLowerAscii();
    check validateKaryawanFields(nik, nama, email);

    string status = payload?.status ?: "AKTIF";
    if !isValidKaryawanStatus(status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    string tipeKaryawan = payload?.tipeKaryawan ?: "P";
    if !isValidTipeKaryawan(tipeKaryawan) {
        return utils:validationError("Tipe karyawan harus P (Pegawai Tetap) atau C (Kontrak)");
    }

    check validateKaryawanUnit(payload.unitId);
    check validateKaryawanJabatan(payload.jabatanId);

    // Uniqueness checks — friendly 409s instead of raw DB constraint errors.
    if check repositories:nikExists(nik, 0) {
        return utils:conflictError("NIK sudah digunakan");
    }
    if check repositories:emailExists(email, 0) {
        return utils:conflictError("Email sudah digunakan");
    }

    string? subjectId = check resolveSubjectId(payload?.subjectId, 0);

    string? noHp = trimToNil(payload?.noHp);
    check validateNoHp(noHp);
    string? tanggalMasuk = trimToNil(payload?.tanggalMasuk);

    int newId = check repositories:insertKaryawan(nik, nama, payload.jabatanId, payload.unitId, tipeKaryawan,
            email, noHp, tanggalMasuk, status, subjectId, subject);

    models:KaryawanDetail? created = check repositories:findKaryawanById(newId);
    if created is () {
        return error("Karyawan created (id " + newId.toString() + ") but could not be read back");
    }
    logAudit("karyawan", newId.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates an existing karyawan. Re-checks uniqueness (excluding the row itself) and lets
# subject_id be set, changed, or cleared.
#
# + id - the karyawan id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated karyawan detail, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateKaryawan(int id, models:KaryawanUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:KaryawanDetail|error {
    string nik = payload.nik.trim();
    string nama = payload.nama.trim();
    string email = payload.email.trim().toLowerAscii();
    check validateKaryawanFields(nik, nama, email);

    if !isValidKaryawanStatus(payload.status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }

    string tipeKaryawan = payload?.tipeKaryawan ?: "P";
    if !isValidTipeKaryawan(tipeKaryawan) {
        return utils:validationError("Tipe karyawan harus P (Pegawai Tetap) atau C (Kontrak)");
    }

    check validateKaryawanUnit(payload.unitId);
    check validateKaryawanJabatan(payload.jabatanId);

    models:KaryawanDetail? existing = check repositories:findKaryawanById(id);
    if existing is () {
        return utils:notFoundError("Karyawan dengan id " + id.toString() + " tidak ditemukan");
    }

    if check repositories:nikExists(nik, id) {
        return utils:conflictError("NIK sudah digunakan");
    }
    if check repositories:emailExists(email, id) {
        return utils:conflictError("Email sudah digunakan");
    }

    string? subjectId = check resolveSubjectId(payload?.subjectId, id);

    string? noHp = trimToNil(payload?.noHp);
    check validateNoHp(noHp);
    string? tanggalMasuk = trimToNil(payload?.tanggalMasuk);

    int? updatedId = check repositories:updateKaryawan(id, nik, nama, payload.jabatanId,
            payload.unitId, tipeKaryawan, email, noHp, tanggalMasuk, payload.status, subjectId, subject);
    if updatedId is () {
        return utils:notFoundError("Karyawan dengan id " + id.toString() + " tidak ditemukan");
    }

    models:KaryawanDetail? updated = check repositories:findKaryawanById(id);
    if updated is () {
        return utils:notFoundError("Karyawan dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("karyawan", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Lists karyawan as a lightweight dropdown projection ({id, nama, unitNama}), unpaginated.
#
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF); omitted defaults to AKTIF only
# + search - optional ILIKE filter on nama
# + return - the matching karyawan options, a VALIDATION_ERROR AppError, or an error
public function getKaryawanDropdown(int? unitId, string? status, string? search)
        returns models:KaryawanDropdownItem[]|error {
    if status is string && status.trim().length() > 0 && !isValidKaryawanStatus(status) {
        return utils:validationError("Status harus AKTIF atau TIDAK_AKTIF");
    }
    return repositories:findKaryawanDropdown(unitId, status, search);
}

# Soft-deletes a karyawan after ensuring it exists and is not an active reference anywhere.
#
# + id - the karyawan id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteKaryawan(int id, string subject, string? ipAddress = ()) returns error? {
    models:KaryawanDetail? existing = check repositories:findKaryawanById(id);
    if existing is () {
        return utils:notFoundError("Karyawan dengan id " + id.toString() + " tidak ditemukan");
    }

    // Five independent EXISTS checks (customer, proyek pic/pmo, team_member, resource_unit),
    // combined here rather than as one big JOIN so each dependency stays readable.
    boolean refCustomer = check repositories:isReferencedByCustomer(id);
    boolean refProyek = check repositories:isReferencedByProyek(id);
    boolean refTeam = check repositories:isReferencedByTeamMember(id);
    boolean refResourceUnit = check repositories:isReferencedByResourceUnit(id);
    if refCustomer || refProyek || refTeam || refResourceUnit {
        return utils:conflictError(
            "Karyawan tidak dapat dihapus karena masih menjadi rujukan aktif pada Customer/Proyek/Team/Resource Unit");
    }

    boolean deleted = check repositories:softDeleteKaryawan(id, subject);
    if !deleted {
        return utils:notFoundError("Karyawan dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("karyawan", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Computes the standard-format NIK a create would suggest RIGHT NOW, without reserving anything —
# a pure read (SELECT MAX(urutan)+1), no transaction, no lock, no insert. Mirrors
# nomor_surat_service:previewNomor. Format: `{prefix}-{tahunMasuk2Digit}{urutan:3}{tipeKaryawan}
# {unit.kodeNik}` (e.g. "SWA-22309CSD") — see the module-level format note below `previewNik`'s
# callers in main.bal and documentation/note/api/03-master-data.md#modul-karyawan. `tahun`
# defaults to the current calendar year when the caller hasn't picked a tanggal masuk yet; pass
# the actual tanggal-masuk year once known for an accurate suggestion. Calling this twice with no
# create in between yields the same value; if another request commits a create first for the same
# year, the value simply advances — that non-reservation is intentional, nik stays a free-text
# field the caller can still override, and `nikExists` on create/update is the actual safety net
# (see `getNextNikUrutan`'s doc for why there is no atomic counterpart here).
#
# NEVER suggests the founder/original-management format (`SWA-00001OCO` style) — that format is
# frozen historical data for the company's founding cohort (see karyawan_seed.sql), not something
# new hires (even Direktur/Manager-titled ones) ever get going forward.
#
# + unitId - the selected unit id (required — its `kode_nik` feeds the suggestion)
# + tipeKaryawan - "P" (Pegawai Tetap) or "C" (Kontrak)
# + tahun - optional numbering year (defaults to the current calendar year)
# + return - the previewed next NIK, a VALIDATION_ERROR AppError (bad tipeKaryawan/unit), or an error
public function previewNik(int unitId, string tipeKaryawan, int? tahun) returns models:KaryawanNikPreview|error {
    if !isValidTipeKaryawan(tipeKaryawan) {
        return utils:validationError("Tipe karyawan harus P (Pegawai Tetap) atau C (Kontrak)");
    }
    models:Unit? unit = check repositories:findUnitById(unitId);
    if unit is () {
        return utils:validationError("Unit tidak ditemukan");
    }

    int effectiveTahun = tahun ?: currentNikYear();
    string tahun2Digit = repositories:pad2Digit(effectiveTahun);
    string prefix = check resolveNikPrefix();
    int urutan = check repositories:getNextNikUrutan(prefix, tahun2Digit);
    return {nikPreview: repositories:formatNik(prefix, tahun2Digit, urutan, tipeKaryawan, unit.kodeNik)};
}

# The current calendar year (server time), used as the default `tahun` for `previewNik` when the
# caller omits it. Deliberately its own copy rather than reusing nomor_surat_service:currentYear /
# proyek_service:currentProyekYear — same precedent as those two not sharing with each other.
#
# + return - the current calendar year
function currentNikYear() returns int {
    time:Civil civil = time:utcToCivil(time:utcNow());
    return civil.year;
}

# Resolves the NIK prefix from sys_config. The `prefix_nik` row is guaranteed to be seeded
# (swamedia_portal_schema_v2.1.sql), so a missing/blank row is treated as a serious configuration
# bug, NOT a condition to silently tolerate with a hardcoded fallback — mirrors
# nomor_surat_service:resolvePrefix / proyek_service:resolveKodeProyekPrefix.
#
# + return - the trimmed NIK prefix, or an error
function resolveNikPrefix() returns string|error {
    string? prefix = check repositories:getPrefixNik();
    if prefix is () || prefix.trim().length() == 0 {
        log:printError("Konfigurasi sys_config.prefix_nik tidak ditemukan -- modul Karyawan "
                + "tidak dapat menyarankan NIK tanpa konfigurasi ini, periksa seeding database");
        return utils:internalError("Terjadi kesalahan pada server, silakan coba lagi nanti");
    }
    return prefix.trim();
}

# Validates nik (1-30), nama (3-150) and email (required + format).
#
# + nik - the employee id number to validate
# + nama - the employee name to validate
# + email - the employee email to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateKaryawanFields(string nik, string nama, string email) returns models:AppError? {
    if nik.length() < 1 || nik.length() > 30 {
        return utils:validationError("NIK wajib diisi, panjang 1-30 karakter");
    }
    if nama.length() < 3 || nama.length() > 150 {
        return utils:validationError("Nama wajib diisi, panjang 3-150 karakter");
    }
    if email.length() == 0 {
        return utils:validationError("Email wajib diisi");
    }
    if !EMAIL_PATTERN.isFullMatch(email) {
        return utils:validationError("Format email tidak valid");
    }
    return ();
}

# Validates noHp (optional): maximum 20 characters (matches the DB column's VARCHAR(20)),
# so an over-long phone number surfaces as a friendly 400 instead of a raw DB error.
#
# + noHp - the optional phone number to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid/absent
function validateNoHp(string? noHp) returns models:AppError? {
    if noHp is string && noHp.length() > 20 {
        return utils:validationError("No HP maksimal 20 karakter");
    }
    return ();
}

# Ensures the referenced unit exists and is not deleted.
#
# + unitId - the unit id to validate
# + return - a VALIDATION_ERROR AppError if not found, () if valid, or an error
function validateKaryawanUnit(int unitId) returns models:AppError|error? {
    boolean unitOk = check repositories:unitExistsActive(unitId);
    if !unitOk {
        return utils:validationError("Unit tidak ditemukan");
    }
    return ();
}

# Ensures the referenced jabatan_master row exists and is AKTIF. `jabatan_id` is NOT NULL in
# the DB, so unlike unit this is a hard requirement, not an optional FK.
#
# + jabatanId - the jabatan_master id to validate
# + return - a VALIDATION_ERROR AppError if not found/inactive, () if valid, or an error
function validateKaryawanJabatan(int jabatanId) returns models:AppError|error? {
    boolean jabatanOk = check repositories:jabatanExistsActive(jabatanId);
    if !jabatanOk {
        return utils:validationError("Jabatan tidak ditemukan");
    }
    return ();
}

# Normalizes and (when present) uniqueness-checks the incoming subject_id.
#
# SECURITY-SENSITIVE: an empty/blank subject_id means "no portal account" (a valid, normal
# state) and is stored as NULL. A non-empty subject_id must be unique across karyawan — a
# duplicate would mean two employee records claim the same WSO2 IS identity, so we reject it
# with 409 before hitting the DB constraint.
#
# + raw - the subject_id from the request body (may be nil/blank)
# + excludeId - the karyawan id to exclude from the uniqueness check (0 on create)
# + return - the normalized subject_id (() when blank), a CONFLICT AppError, or an error
function resolveSubjectId(string? raw, int excludeId) returns string?|error {
    string? normalized = trimToNil(raw);
    if normalized is () {
        return ();
    }
    if check repositories:isSubjectIdTaken(normalized, excludeId) {
        return utils:conflictError("subject_id sudah ditautkan ke karyawan lain");
    }
    return normalized;
}

# Trims a nullable string, returning () when it is nil or blank after trimming.
#
# + value - the nullable string to trim
# + return - the trimmed string, or () if nil/blank
function trimToNil(string? value) returns string? {
    if value is () {
        return ();
    }
    string trimmed = value.trim();
    return trimmed.length() == 0 ? () : trimmed;
}

function isValidKaryawanStatus(string status) returns boolean {
    return status == "AKTIF" || status == "TIDAK_AKTIF";
}

function isValidTipeKaryawan(string tipeKaryawan) returns boolean {
    return tipeKaryawan == "P" || tipeKaryawan == "C";
}
