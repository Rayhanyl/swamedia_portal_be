import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Karyawan repository =====
#
# All access to the `karyawan` table. Parameterized `sql:ParameterizedQuery` templates only.
# NOTE: the list query intentionally does NOT select `subject_id` — it maps to KaryawanListItem
# (which has no subjectId field), keeping the WSO2 IS link out of list responses. Only
# `findKaryawanById` (mapping to KaryawanDetail) exposes subject_id.
#
# `jabatan` is embedded as a nested `JabatanRef` (JOIN to jabatan_master) in every response —
# the SQL client binds flat columns only, so queries select a flat row type first and the
# functions below fold `jabatanId`/`namaJabatan`/`kategori` into the nested record before
# returning. `karyawan.jabatan_id` is NOT NULL, so the JOIN is a plain INNER JOIN.

# Flat projection of a karyawan list row plus its joined jabatan_master columns — the shape
# the SQL client can bind directly, before folding into the nested `models:KaryawanListItem`.
#
# + id - primary key
# + nik - unique employee id number
# + nama - employee name
# + jabatanId - jabatan_master id (FK)
# + namaJabatan - joined jabatan_master name
# + kategori - joined jabatan_master category
# + unitId - owning unit id
# + email - employee email
# + noHp - optional phone number
# + tanggalMasuk - optional join date (YYYY-MM-DD)
# + status - AKTIF / TIDAK_AKTIF
type KaryawanListRow record {|
    int id;
    string nik;
    string nama;
    int jabatanId;
    string namaJabatan;
    string kategori;
    int unitId;
    string tipeKaryawan;
    string email;
    string? noHp;
    string? tanggalMasuk;
    string status;
|};

# Flat projection of a karyawan detail row plus its joined jabatan_master columns — the shape
# the SQL client can bind directly, before folding into the nested `models:KaryawanDetail`.
#
# + id - primary key
# + nik - unique employee id number
# + nama - employee name
# + jabatanId - jabatan_master id (FK)
# + namaJabatan - joined jabatan_master name
# + kategori - joined jabatan_master category
# + unitId - owning unit id
# + email - employee email
# + noHp - optional phone number
# + tanggalMasuk - optional join date (YYYY-MM-DD)
# + status - AKTIF / TIDAK_AKTIF
# + subjectId - optional linked WSO2 IS user id
# + createdAt - creation timestamp
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim
# + updatedBy - last updater's `sub` claim, or ()
type KaryawanDetailRow record {|
    int id;
    string nik;
    string nama;
    int jabatanId;
    string namaJabatan;
    string kategori;
    int unitId;
    string tipeKaryawan;
    string email;
    string? noHp;
    string? tanggalMasuk;
    string status;
    string? subjectId;
    string createdAt;
    string? updatedAt;
    string createdBy;
    string? updatedBy;
|};

# Fetches one page of non-deleted karyawan (list projection) matching the optional filters,
# plus the total count. `search` matches nik, nama or email (ILIKE).
#
# + search - optional case-insensitive filter on nik/nama/email
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findKaryawan(string? search, int? unitId, string? status, int 'limit, int offset)
        returns record {|models:KaryawanListItem[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (k.nik ILIKE ${pattern} OR k.nama ILIKE ${pattern} OR k.email ILIKE ${pattern})`);
    }
    if unitId is int {
        conditions.push(` AND k.unit_id = ${unitId}`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND k.status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT k.id, k.nik, k.nama, k.jabatan_id AS "jabatanId",
                jm.nama_jabatan AS "namaJabatan", jm.kategori AS "kategori",
                k.unit_id AS "unitId", k.tipe_karyawan AS "tipeKaryawan", k.email, k.no_hp AS "noHp",
                k.tanggal_masuk::text AS "tanggalMasuk", k.status
         FROM karyawan k
         JOIN jabatan_master jm ON jm.id = k.jabatan_id
         WHERE k.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY k.id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    KaryawanListRow[] rows = check from KaryawanListRow r in dbc->query(selectQuery, KaryawanListRow) select r;
    models:KaryawanListItem[] items = from KaryawanListRow r in rows
        select {
            id: r.id,
            nik: r.nik,
            nama: r.nama,
            jabatan: {id: r.jabatanId, namaJabatan: r.namaJabatan, kategori: r.kategori},
            unitId: r.unitId,
            tipeKaryawan: r.tipeKaryawan,
            email: r.email,
            noHp: r.noHp,
            tanggalMasuk: r.tanggalMasuk,
            status: r.status
        };

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM karyawan k WHERE k.is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted karyawan (detail projection, including subject_id + audit) by id.
#
# + id - the karyawan id
# + return - the karyawan detail, `()` if not found (or already deleted), or an error
public function findKaryawanById(int id) returns models:KaryawanDetail?|error {
    postgresql:Client dbc = check dbClient();
    KaryawanDetailRow|sql:Error result = dbc->queryRow(`
        SELECT k.id, k.nik, k.nama, k.jabatan_id AS "jabatanId",
               jm.nama_jabatan AS "namaJabatan", jm.kategori AS "kategori",
               k.unit_id AS "unitId", k.tipe_karyawan AS "tipeKaryawan", k.email, k.no_hp AS "noHp",
               k.tanggal_masuk::text AS "tanggalMasuk", k.status, k.subject_id AS "subjectId",
               k.created_at::text AS "createdAt", k.updated_at::text AS "updatedAt",
               k.created_by AS "createdBy", k.updated_by AS "updatedBy"
        FROM karyawan k
        JOIN jabatan_master jm ON jm.id = k.jabatan_id
        WHERE k.id = ${id} AND k.is_deleted = false`, KaryawanDetailRow);
    if result is sql:NoRowsError {
        return ();
    }
    if result is sql:Error {
        return result;
    }
    return toKaryawanDetail(result);
}

# Fetches a single non-deleted karyawan (detail projection, including subject_id + audit) by its
# linked WSO2 IS subject_id — used by the Profil Saya / Notifikasi self-service modules to resolve
# "the karyawan record for the currently logged-in user" from the access token's `sub` claim.
#
# + subjectId - the WSO2 IS subject to look up
# + return - the karyawan detail, `()` if no karyawan is linked to that subject, or an error
public function findKaryawanBySubjectId(string subjectId) returns models:KaryawanDetail?|error {
    postgresql:Client dbc = check dbClient();
    KaryawanDetailRow|sql:Error result = dbc->queryRow(`
        SELECT k.id, k.nik, k.nama, k.jabatan_id AS "jabatanId",
               jm.nama_jabatan AS "namaJabatan", jm.kategori AS "kategori",
               k.unit_id AS "unitId", k.tipe_karyawan AS "tipeKaryawan", k.email, k.no_hp AS "noHp",
               k.tanggal_masuk::text AS "tanggalMasuk", k.status, k.subject_id AS "subjectId",
               k.created_at::text AS "createdAt", k.updated_at::text AS "updatedAt",
               k.created_by AS "createdBy", k.updated_by AS "updatedBy"
        FROM karyawan k
        JOIN jabatan_master jm ON jm.id = k.jabatan_id
        WHERE k.subject_id = ${subjectId} AND k.is_deleted = false`, KaryawanDetailRow);
    if result is sql:NoRowsError {
        return ();
    }
    if result is sql:Error {
        return result;
    }
    return toKaryawanDetail(result);
}

# Folds a flat `KaryawanDetailRow` (post-JOIN) into the nested `models:KaryawanDetail` shape.
# Shared by `findKaryawanById` and `findKaryawanBySubjectId` so the two lookups can never drift.
#
# + r - the flat detail row
# + return - the nested karyawan detail
function toKaryawanDetail(KaryawanDetailRow r) returns models:KaryawanDetail => {
    id: r.id,
    nik: r.nik,
    nama: r.nama,
    jabatan: {id: r.jabatanId, namaJabatan: r.namaJabatan, kategori: r.kategori},
    unitId: r.unitId,
    tipeKaryawan: r.tipeKaryawan,
    email: r.email,
    noHp: r.noHp,
    tanggalMasuk: r.tanggalMasuk,
    status: r.status,
    subjectId: r.subjectId,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    createdBy: r.createdBy,
    updatedBy: r.updatedBy
};

# Returns whether a non-deleted karyawan with the given id exists (used to validate FK refs
# from other masters, e.g. customer.am_id).
#
# + id - the karyawan id to check
# + return - true if an active karyawan with that id exists, or an error
public function karyawanExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM karyawan WHERE id = ${id} AND is_deleted = false`);
    return count > 0;
}

# Returns whether another non-deleted karyawan already uses the given nik.
#
# + nik - the nik to check
# + excludeId - a karyawan id to exclude (0 = none)
# + return - true if a conflicting nik exists, or an error
public function nikExists(string nik, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM karyawan
        WHERE nik = ${nik} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Reads the NIK prefix from sys_config (key = 'prefix_nik'). Mirrors
# nomor_surat_repository:getPrefixNomorSurat / proyek_repository:getPrefixKodeProyek.
#
# + return - the configured prefix, or `()` when the row is missing or its value is NULL, or an error
public function getPrefixNik() returns string?|error {
    postgresql:Client dbc = check dbClient();
    record {|string? value;|}|sql:Error row =
        dbc->queryRow(`SELECT value FROM sys_config WHERE key = 'prefix_nik'`);
    if row is sql:NoRowsError {
        return ();
    }
    if row is sql:Error {
        return row;
    }
    return row.value;
}

# Read-only next urutan for (prefix, tahunMasuk2Digit) — MAX(urutan)+1 parsed back out of every
# existing standard-format `nik` value for that 2-digit tahun masuk (across ALL rows, including
# soft-deleted, so a historic number is never suggested again even after a karyawan is deleted).
# The numbering is GLOBAL across the whole company for that year — NOT scoped per unit or per
# tipe_karyawan (verified against karyawan_seed.sql: e.g. year "17" mixes P and C rows, and
# multiple units, inside one shared ascending sequence 197/199/208/211/222).
#
# Founder/original-management NIKs (`SWA-00001OCO` .. `SWA-00008OMS`) use a completely different,
# frozen, non-year-based numbering ("O" marker, no P/C letter) — see the module-level format note
# in karyawan_service.bal. They never match this pattern, so they are naturally excluded here;
# this function must NEVER be used to suggest a new founder-format NIK.
#
# PREVIEW only: no lock is taken and nothing is reserved, unlike `nomor_surat`/`kode_proyek` there
# is no atomic generate+insert counterpart here — nik stays a free-text field the caller can still
# override, and the existing `nikExists` uniqueness check on create/update remains the actual
# safety net.
#
# + prefix - the sys_config prefix (e.g. "SWA")
# + tahunMasuk2Digit - the 2-digit tahun masuk, e.g. "22" for 2022 (see `pad2Digit`)
# + return - the next urutan (1 when no rows exist yet), or an error
public function getNextNikUrutan(string prefix, string tahunMasuk2Digit) returns int|error {
    postgresql:Client dbc = check dbClient();
    string likePattern = prefix + "-" + tahunMasuk2Digit + "%";
    // Anchored on the tahun-masuk digits only (not the admin-configurable prefix) — the LIKE
    // clause above already scopes which rows are considered, so the prefix itself never needs to
    // appear inside the regex.
    string pattern = "-" + tahunMasuk2Digit + "([0-9]{3})[PC][A-Z]{2}$";
    int next = check dbc->queryRow(`
        SELECT COALESCE(MAX((regexp_match(nik, ${pattern}))[1]::int), 0) + 1
        FROM karyawan
        WHERE nik LIKE ${likePattern}`);
    return next;
}

# Builds the canonical standard-format NIK string from its parts:
# `{prefix}-{tahunMasuk2Digit}{urutan, zero-padded to 3 digits}{tipeKaryawan}{kodeNik}`
# (e.g. "SWA-22309CSD"). Single source of truth for the format. Reuses `padUrutan` from
# `nomor_surat_repository.bal` — both files live in the `repositories` module, so a module-private
# function defined in one is already visible in the other. NEVER used for the founder/original-
# management format (`SWA-00001OCO` style) — those are frozen historical values, never generated.
#
# + prefix - the sys_config prefix (e.g. "SWA")
# + tahunMasuk2Digit - the 2-digit tahun masuk, e.g. "22" for 2022
# + urutan - the sequence number within (prefix, tahunMasuk2Digit), global company-wide
# + tipeKaryawan - "P" (Pegawai Tetap) or "C" (Kontrak)
# + kodeNik - the unit's 2-letter legacy NIK code (`unit.kode_nik`)
# + return - e.g. "SWA-22309CSD"
public isolated function formatNik(string prefix, string tahunMasuk2Digit, int urutan, string tipeKaryawan,
        string kodeNik) returns string {
    return string `${prefix}-${tahunMasuk2Digit}${padUrutan(urutan)}${tipeKaryawan}${kodeNik}`;
}

# Left-pads a 4-digit year down to its 2 trailing digits (2022 -> "22", 2007 -> "07").
#
# + tahun - a 4-digit calendar year
# + return - the 2-digit string
public isolated function pad2Digit(int tahun) returns string {
    int last2 = tahun % 100;
    string s = last2.toString();
    return s.length() < 2 ? "0" + s : s;
}

# Returns whether another non-deleted karyawan already uses the given email (case-insensitive).
#
# + emailLower - the lowercased email to check
# + excludeId - a karyawan id to exclude (0 = none)
# + return - true if a conflicting email exists, or an error
public function emailExists(string emailLower, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM karyawan
        WHERE lower(email) = ${emailLower} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether the given WSO2 IS subject_id is already linked to another karyawan.
# SECURITY-SENSITIVE: subject_id ties a karyawan record to a real WSO2 IS identity. This
# manual uniqueness check both gives a friendly 409 (instead of a raw DB constraint error)
# and prevents accidentally/maliciously re-pointing one IS identity at a second karyawan
# record. See the service layer for the rest of the rationale.
#
# + subjectId - the subject_id to check
# + excludeId - a karyawan id to exclude (0 = none)
# + return - true if the subject_id is already taken, or an error
public function isSubjectIdTaken(string subjectId, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM karyawan
        WHERE subject_id = ${subjectId} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether an active customer still references this karyawan as its account manager.
#
# + id - the karyawan id
# + return - true if referenced by an active customer.am_id, or an error
public function isReferencedByCustomer(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM customer WHERE am_id = ${id} AND is_deleted = false)`);
    return referenced;
}

# Returns whether an active proyek still references this karyawan as PIC Sales or PMO.
#
# + id - the karyawan id
# + return - true if referenced by an active proyek.pic_sales_id or proyek.pmo_id, or an error
public function isReferencedByProyek(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(`
        SELECT EXISTS(SELECT 1 FROM proyek
                      WHERE (pic_sales_id = ${id} OR pmo_id = ${id}) AND is_deleted = false)`);
    return referenced;
}

# Returns whether this karyawan is still an active team member of any proyek.
#
# + id - the karyawan id
# + return - true if referenced by an active team_member.karyawan_id, or an error
public function isReferencedByTeamMember(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM team_member WHERE karyawan_id = ${id} AND is_deleted = false)`);
    return referenced;
}

# Returns whether this karyawan is still the lead of any active resource_unit.
#
# + id - the karyawan id
# + return - true if referenced by an active resource_unit.lead_id, or an error
public function isReferencedByResourceUnit(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM resource_unit WHERE lead_id = ${id} AND is_deleted = false)`);
    return referenced;
}

# Inserts a new karyawan and returns its generated id (the service re-reads the joined detail
# via `findKaryawanById`, mirroring the pattern in customer_repository).
#
# + nik - employee id number
# + nama - full name
# + jabatanId - jabatan_master id (FK, NOT NULL)
# + unitId - owning unit id
# + tipeKaryawan - "P" (Pegawai Tetap) or "C" (Kontrak)
# + email - lowercased email
# + noHp - phone number, or ()
# + tanggalMasuk - join date as an ISO string (YYYY-MM-DD), or ()
# + status - AKTIF / TIDAK_AKTIF
# + subjectId - linked WSO2 IS subject, or () for no portal account
# + createdBy - the `sub` claim of the caller
# + return - the new karyawan id, or an error
public function insertKaryawan(string nik, string nama, int jabatanId, int unitId, string tipeKaryawan,
        string email, string? noHp, string? tanggalMasuk, string status, string? subjectId, string createdBy)
        returns int|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO karyawan (nik, nama, jabatan_id, unit_id, tipe_karyawan, email, no_hp, tanggal_masuk,
                status, subject_id, created_by)
        VALUES (${nik}, ${nama}, ${jabatanId}, ${unitId}, ${tipeKaryawan}, ${email}, ${noHp}, ${tanggalMasuk}::date,
                ${status}, ${subjectId}, ${createdBy})
        RETURNING id`);
    return newId;
}

# Updates a non-deleted karyawan and returns its id (the service re-reads the joined detail
# via `findKaryawanById`, mirroring the pattern in customer_repository).
#
# + id - the karyawan id
# + nik - new nik
# + nama - new name
# + jabatanId - new jabatan_master id (FK, NOT NULL)
# + unitId - new owning unit id
# + tipeKaryawan - new "P"/"C"
# + email - new lowercased email
# + noHp - new phone number, or ()
# + tanggalMasuk - new join date (YYYY-MM-DD), or ()
# + status - new status
# + subjectId - new linked subject, or () to unlink
# + updatedBy - the `sub` claim of the caller
# + return - the karyawan id, `()` if the row does not exist (or is deleted), or an error
public function updateKaryawan(int id, string nik, string nama, int jabatanId, int unitId, string tipeKaryawan,
        string email, string? noHp, string? tanggalMasuk, string status, string? subjectId, string updatedBy)
        returns int?|error {
    postgresql:Client dbc = check dbClient();
    int|sql:Error updated = dbc->queryRow(`
        UPDATE karyawan SET nik = ${nik}, nama = ${nama}, jabatan_id = ${jabatanId}, unit_id = ${unitId},
               tipe_karyawan = ${tipeKaryawan}, email = ${email}, no_hp = ${noHp},
               tanggal_masuk = ${tanggalMasuk}::date,
               status = ${status}, subject_id = ${subjectId}, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id`, int);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Updates ONLY the contact fields (email, no_hp) of a non-deleted karyawan — used by the Profil
# Saya self-service update, which deliberately cannot touch nik/nama/jabatan/unit/status/subject_id
# (those stay HR-managed via `updateKaryawan`).
#
# + id - the karyawan id
# + email - new lowercased email
# + noHp - new phone number, or () to clear it
# + updatedBy - the `sub` claim of the caller (the karyawan themself)
# + return - the karyawan id, `()` if the row does not exist (or is deleted), or an error
public function updateKaryawanContact(int id, string email, string? noHp, string updatedBy)
        returns int?|error {
    postgresql:Client dbc = check dbClient();
    int|sql:Error updated = dbc->queryRow(`
        UPDATE karyawan SET email = ${email}, no_hp = ${noHp}, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id`, int);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Fetches a lightweight karyawan dropdown projection ({id, nama, unitNama}), unpaginated, for
# the Team Member / Resource Unit / Kontrak Payung harga-per-role forms. Defaults to AKTIF-only
# when `status` is omitted (same convention as `jabatan_master_repository:findJabatan`).
#
# + unitId - optional exact unit_id filter
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF); () defaults to AKTIF only
# + search - optional ILIKE filter on nama
# + return - the matching karyawan options, or an error
public function findKaryawanDropdown(int? unitId, string? status, string? search)
        returns models:KaryawanDropdownItem[]|error {
    postgresql:Client dbc = check dbClient();

    string effectiveStatus = status is string && status.trim().length() > 0 ? status.trim() : "AKTIF";

    sql:ParameterizedQuery[] selectParts = [
        `SELECT k.id, k.nama, u.nama_unit AS "unitNama"
         FROM karyawan k
         JOIN unit u ON u.id = k.unit_id
         WHERE k.is_deleted = false AND k.status = ${effectiveStatus}`
    ];
    if unitId is int {
        selectParts.push(` AND k.unit_id = ${unitId}`);
    }
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        selectParts.push(` AND k.nama ILIKE ${pattern}`);
    }
    selectParts.push(` ORDER BY k.nama ASC`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    return from models:KaryawanDropdownItem d in dbc->query(selectQuery, models:KaryawanDropdownItem)
        select d;
}

# Soft-deletes a karyawan (sets is_deleted = true). Never physically deletes.
#
# + id - the karyawan id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteKaryawan(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE karyawan SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
