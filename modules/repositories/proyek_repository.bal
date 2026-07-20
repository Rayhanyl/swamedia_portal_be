import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Proyek repository =====
#
# All access to the `proyek` and `log_status` tables. Parameterized `sql:ParameterizedQuery`
# templates only. List/detail reads JOIN customer/industri/unit/karyawan (PIC Sales) and LEFT
# JOIN karyawan (PMO) + kontrak_payung + kontrak_biasa to resolve every display name in a single
# query (no N+1).
#
# `kode_proyek` generation mirrors `nomor_surat_repository`'s `no_surat` generation exactly:
# format `{prefix_kode_proyek}-{kodeUnit}-{tahun}-{urutan}` (e.g. "PRJ-MKT-2026-001"), the
# current MAX urutan is parsed back out of existing `kode_proyek` values per (unit_id, tahun) via
# `regexp_match` (no dedicated `urutan` column), and the read-MAX/insert race is closed with a
# `pg_advisory_xact_lock` scoped to that same (unit_id, tahun) pair — see the module-level note in
# nomor_surat_repository for why a bare `transaction { ... }` block alone would not be enough
# under READ COMMITTED. `formatKodeProyek` reuses `padUrutan` from nomor_surat_repository (same
# module, so no need to redefine it).

# Fetches one page of non-deleted proyek matching the optional filters, plus the total count.
# `search` matches kode_proyek or nama_proyek (ILIKE).
#
# + search - optional case-insensitive filter on kode_proyek or nama_proyek
# + customerId - optional exact customer_id filter
# + industriId - optional exact industri_id filter
# + unitId - optional exact unit_id filter
# + picSalesId - optional exact pic_sales_id filter
# + status - optional exact status filter
# + tahun - optional exact tahun filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findProyek(string? search, int? customerId, int? industriId, int? unitId, int? picSalesId,
        string? status, int? tahun, int 'limit, int offset)
        returns record {|models:Proyek[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (p.kode_proyek ILIKE ${pattern} OR p.nama_proyek ILIKE ${pattern})`);
    }
    if customerId is int {
        conditions.push(` AND p.customer_id = ${customerId}`);
    }
    if industriId is int {
        conditions.push(` AND p.industri_id = ${industriId}`);
    }
    if unitId is int {
        conditions.push(` AND p.unit_id = ${unitId}`);
    }
    if picSalesId is int {
        conditions.push(` AND p.pic_sales_id = ${picSalesId}`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND p.status = ${status}`);
    }
    if tahun is int {
        conditions.push(` AND p.tahun = ${tahun}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT p.id, p.kode_proyek AS "kodeProyek",
                p.customer_id AS "customerId", c.nama AS "customerNama",
                p.industri_id AS "industriId", i.nama AS "industriNama",
                p.unit_id AS "unitId", u.nama_unit AS "unitNama",
                p.kontrak_payung_id AS "kontrakPayungId", kp.no_kontrak_payung AS "noKontrakPayung",
                p.kontrak_biasa_id AS "kontrakBiasaId", kb.no_kontrak_biasa AS "noKontrakBiasa",
                p.nama_proyek AS "namaProyek", p.departemen,
                p.nilai_proyek AS "nilaiProyek", p.subkon, p.nilai_bersih AS "nilaiBersih",
                p.pic_sales_id AS "picSalesId", ps.nama AS "picSalesNama",
                p.pmo_id AS "pmoId", pmo.nama AS "pmoNama",
                p.no_kontrak AS "noKontrak",
                p.tanggal_kontrak::text AS "tanggalKontrak",
                p.tanggal_bast::text AS "tanggalBast",
                p.tanggal_mulai::text AS "tanggalMulai",
                p.tanggal_deal::text AS "tanggalDeal",
                p.target_selesai::text AS "targetSelesai",
                p.keterangan_pembayaran AS "keteranganPembayaran",
                p.status, p.tahun
         FROM proyek p
         JOIN customer c ON c.id = p.customer_id
         JOIN industri i ON i.id = p.industri_id
         JOIN unit u ON u.id = p.unit_id
         JOIN karyawan ps ON ps.id = p.pic_sales_id
         LEFT JOIN karyawan pmo ON pmo.id = p.pmo_id
         LEFT JOIN kontrak_payung kp ON kp.id = p.kontrak_payung_id
         LEFT JOIN kontrak_biasa kb ON kb.id = p.kontrak_biasa_id
         WHERE p.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY p.id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Proyek[] items = check from models:Proyek p in dbc->query(selectQuery, models:Proyek)
        select p;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM proyek p WHERE p.is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted proyek (with joined display names + audit columns) by id.
#
# + id - the proyek id
# + return - the proyek, `()` if not found (or already deleted), or an error
public function findProyekById(int id) returns models:Proyek?|error {
    postgresql:Client dbc = check dbClient();
    models:Proyek|sql:Error result = dbc->queryRow(`
        SELECT p.id, p.kode_proyek AS "kodeProyek",
               p.customer_id AS "customerId", c.nama AS "customerNama",
               p.industri_id AS "industriId", i.nama AS "industriNama",
               p.unit_id AS "unitId", u.nama_unit AS "unitNama",
               p.kontrak_payung_id AS "kontrakPayungId", kp.no_kontrak_payung AS "noKontrakPayung",
               p.kontrak_biasa_id AS "kontrakBiasaId", kb.no_kontrak_biasa AS "noKontrakBiasa",
               p.nama_proyek AS "namaProyek", p.departemen,
               p.nilai_proyek AS "nilaiProyek", p.subkon, p.nilai_bersih AS "nilaiBersih",
               p.pic_sales_id AS "picSalesId", ps.nama AS "picSalesNama",
               p.pmo_id AS "pmoId", pmo.nama AS "pmoNama",
               p.no_kontrak AS "noKontrak",
               p.tanggal_kontrak::text AS "tanggalKontrak",
               p.tanggal_bast::text AS "tanggalBast",
               p.tanggal_mulai::text AS "tanggalMulai",
               p.tanggal_deal::text AS "tanggalDeal",
               p.target_selesai::text AS "targetSelesai",
               p.keterangan_pembayaran AS "keteranganPembayaran",
               p.status, p.tahun,
               p.created_at::text AS "createdAt", p.updated_at::text AS "updatedAt",
               p.created_by AS "createdBy", p.updated_by AS "updatedBy"
        FROM proyek p
        JOIN customer c ON c.id = p.customer_id
        JOIN industri i ON i.id = p.industri_id
        JOIN unit u ON u.id = p.unit_id
        JOIN karyawan ps ON ps.id = p.pic_sales_id
        LEFT JOIN karyawan pmo ON pmo.id = p.pmo_id
        LEFT JOIN kontrak_payung kp ON kp.id = p.kontrak_payung_id
        LEFT JOIN kontrak_biasa kb ON kb.id = p.kontrak_biasa_id
        WHERE p.id = ${id} AND p.is_deleted = false`, models:Proyek);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether a non-deleted proyek with the given id exists. Moved here from
# nomor_surat_repository now that the Proyek module exists (nomor_surat_service's
# validateProyek still calls this by name — functions are module-scoped, not file-scoped, so
# nothing else needed to change there).
#
# + id - the proyek id to check
# + return - true if an active proyek with that id exists, or an error
public function proyekExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM proyek WHERE id = ${id} AND is_deleted = false`);
    return count > 0;
}

# Reads the kode_proyek prefix from sys_config (key = 'prefix_kode_proyek').
#
# + return - the configured prefix, or `()` when the row is missing or its value is NULL, or an error
public function getPrefixKodeProyek() returns string?|error {
    postgresql:Client dbc = check dbClient();
    record {|string? value;|}|sql:Error row =
        dbc->queryRow(`SELECT value FROM sys_config WHERE key = 'prefix_kode_proyek'`);
    if row is sql:NoRowsError {
        return ();
    }
    if row is sql:Error {
        return row;
    }
    return row.value;
}

# Generates the next kode_proyek and inserts the row ATOMICALLY (advisory lock closes the
# read-MAX/insert race window, same technique as `nomor_surat_repository:insertNomorSurat` — see
# its module-level note for why this is necessary under READ COMMITTED). Also writes the initial
# `log_status` row for the proyek's starting status, and sets `tanggal_deal` immediately if the
# proyek is created directly at status "DEAL_KONTRAK".
#
# + customerId - the (already validated) customer id
# + industriId - the (already validated) industri id
# + unitId - the (already validated) unit id
# + kodeUnit - the unit's kode_unit, embedded in the generated kode_proyek
# + prefix - the prefix read from sys_config
# + kontrakPayungId - optional (already validated) kontrak_payung id
# + kontrakBiasaId - optional (already validated) kontrak_biasa id
# + namaProyek - proyek name
# + departemen - optional department label
# + nilaiProyek - total project value
# + subkon - subcontractor portion (nilai_bersih = nilaiProyek - subkon, DB-generated)
# + picSalesId - the (already validated) PIC Sales karyawan id
# + pmoId - optional (already validated) PMO karyawan id
# + noKontrak - optional contract number
# + tanggalKontrak - optional contract date (YYYY-MM-DD)
# + tanggalBast - optional BAST date (YYYY-MM-DD)
# + tanggalMulai - optional start date (YYYY-MM-DD)
# + targetSelesai - optional target completion date (YYYY-MM-DD)
# + keteranganPembayaran - optional payment notes
# + status - the initial status
# + tahun - the numbering year (also embedded in kode_proyek)
# + createdBy - the `sub` claim of the caller
# + return - the new proyek id, or an error (lock timeout or unique-constraint violation on race)
public function insertProyek(int customerId, int industriId, int unitId, string kodeUnit, string prefix,
        int? kontrakPayungId, int? kontrakBiasaId, string namaProyek, string? departemen, decimal nilaiProyek,
        decimal subkon, int picSalesId, int? pmoId, string? noKontrak, string? tanggalKontrak,
        string? tanggalBast, string? tanggalMulai, string? targetSelesai, string? keteranganPembayaran,
        string status, int tahun, string createdBy) returns int|error {
    postgresql:Client dbc = check dbClient();
    string lockKey = unitId.toString() + "-" + tahun.toString();
    int newId = 0;
    transaction {
        _ = check dbc->execute(`SET LOCAL lock_timeout = '5s'`);
        _ = check dbc->queryRow(
            `SELECT pg_advisory_xact_lock(hashtext(${lockKey})) IS NULL AS locked`, boolean);

        int nextUrutan = check dbc->queryRow(`
            SELECT COALESCE(MAX((regexp_match(kode_proyek, '-([0-9]+)$'))[1]::int), 0) + 1
            FROM proyek
            WHERE unit_id = ${unitId} AND tahun = ${tahun}`);
        string kodeProyek = formatKodeProyek(prefix, kodeUnit, tahun, nextUrutan);

        newId = check dbc->queryRow(`
            INSERT INTO proyek (kode_proyek, customer_id, industri_id, unit_id, kontrak_payung_id,
                    kontrak_biasa_id, nama_proyek, departemen, nilai_proyek, subkon, pic_sales_id,
                    pmo_id, no_kontrak, tanggal_kontrak, tanggal_bast, tanggal_mulai, target_selesai,
                    keterangan_pembayaran, status, tahun, created_by)
            VALUES (${kodeProyek}, ${customerId}, ${industriId}, ${unitId}, ${kontrakPayungId},
                    ${kontrakBiasaId}, ${namaProyek}, ${departemen}, ${nilaiProyek}, ${subkon}, ${picSalesId},
                    ${pmoId}, ${noKontrak}, ${tanggalKontrak}::date, ${tanggalBast}::date, ${tanggalMulai}::date,
                    ${targetSelesai}::date, ${keteranganPembayaran}, ${status}, ${tahun}, ${createdBy})
            RETURNING id`);

        if status == "DEAL_KONTRAK" {
            _ = check dbc->execute(`UPDATE proyek SET tanggal_deal = CURRENT_DATE WHERE id = ${newId}`);
        }

        _ = check dbc->execute(`
            INSERT INTO log_status (proyek_id, status, komentar, tanggal, created_by)
            VALUES (${newId}, ${status}, 'Status awal saat proyek dibuat', CURRENT_DATE, ${createdBy})`);

        check commit;
    }
    return newId;
}

# Updates the mutable fields of a non-deleted proyek (never `kode_proyek`/`unit_id`/`tahun` — see
# the `Proyek` model doc for why). Reads the current status with `FOR UPDATE` inside the same
# transaction as the write, so a concurrent status-changing update can't race past this one
# un-logged. Whenever `status` actually differs from the current value, writes a `log_status` row
# and — the first time the proyek transitions into "DEAL_KONTRAK" — sets `tanggal_deal` to today
# (only if it was still unset; never overwrites an existing tanggal_deal).
#
# + id - the proyek id
# + customerId - new customer id
# + industriId - new industri id
# + kontrakPayungId - new kontrak_payung id, or () to clear it
# + kontrakBiasaId - new kontrak_biasa id, or () to clear it
# + namaProyek - new proyek name
# + departemen - new department label, or () to clear it
# + nilaiProyek - new total project value
# + subkon - new subcontractor portion
# + picSalesId - new PIC Sales karyawan id
# + pmoId - new PMO karyawan id, or () to clear it
# + noKontrak - new contract number, or () to clear it
# + tanggalKontrak - new contract date, or () to clear it
# + tanggalBast - new BAST date, or () to clear it
# + tanggalMulai - new start date, or () to clear it
# + targetSelesai - new target completion date, or () to clear it
# + keteranganPembayaran - new payment notes, or () to clear it
# + status - new status
# + statusKomentar - optional note recorded on the log_status row, only used if status changed
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was deleted), or an error
public function updateProyek(int id, int customerId, int industriId, int? kontrakPayungId, int? kontrakBiasaId,
        string namaProyek, string? departemen, decimal nilaiProyek, decimal subkon, int picSalesId, int? pmoId,
        string? noKontrak, string? tanggalKontrak, string? tanggalBast, string? tanggalMulai,
        string? targetSelesai, string? keteranganPembayaran, string status, string? statusKomentar,
        string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean found = false;
    transaction {
        record {|string status;|}|sql:Error current = dbc->queryRow(
            `SELECT status FROM proyek WHERE id = ${id} AND is_deleted = false FOR UPDATE`);
        if current is sql:NoRowsError {
            check commit;
        } else {
            record {|string status;|} row = check current;
            found = true;

            _ = check dbc->execute(`
                UPDATE proyek SET customer_id = ${customerId}, industri_id = ${industriId},
                       kontrak_payung_id = ${kontrakPayungId}, kontrak_biasa_id = ${kontrakBiasaId},
                       nama_proyek = ${namaProyek}, departemen = ${departemen},
                       nilai_proyek = ${nilaiProyek}, subkon = ${subkon},
                       pic_sales_id = ${picSalesId}, pmo_id = ${pmoId},
                       no_kontrak = ${noKontrak}, tanggal_kontrak = ${tanggalKontrak}::date,
                       tanggal_bast = ${tanggalBast}::date, tanggal_mulai = ${tanggalMulai}::date,
                       target_selesai = ${targetSelesai}::date, keterangan_pembayaran = ${keteranganPembayaran},
                       status = ${status},
                       tanggal_deal = CASE WHEN ${status} = 'DEAL_KONTRAK' AND tanggal_deal IS NULL
                                            THEN CURRENT_DATE ELSE tanggal_deal END,
                       updated_by = ${updatedBy}, updated_at = now()
                WHERE id = ${id}`);

            if row.status != status {
                _ = check dbc->execute(`
                    INSERT INTO log_status (proyek_id, status, komentar, tanggal, created_by)
                    VALUES (${id}, ${status}, ${statusKomentar}, CURRENT_DATE, ${updatedBy})`);
            }
            check commit;
        }
    }
    return found;
}

# Soft-deletes a proyek (sets is_deleted = true). Never physically deletes.
#
# + id - the proyek id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteProyek(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE proyek SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}

# Fetches the full status-transition history of a proyek, newest first.
#
# + proyekId - the proyek id
# + return - the log_status rows for this proyek, or an error
public function findProyekLogStatus(int proyekId) returns models:ProyekLogStatus[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:ProyekLogStatus l in dbc->query(`
            SELECT id, proyek_id AS "proyekId", status, komentar, tanggal::text AS "tanggal",
                   created_at::text AS "createdAt", created_by AS "createdBy"
            FROM log_status
            WHERE proyek_id = ${proyekId} AND is_deleted = false
            ORDER BY tanggal DESC, id DESC`, models:ProyekLogStatus)
        select l;
}

# Returns up to 100 active proyek (newest first) for the "Project Tujuan" dropdown, optionally
# filtered by a case-insensitive search over kode_proyek / nama_proyek. Intentionally selects only
# the id + display fields — no heavy columns (nilai_proyek, etc.).
#
# + search - optional case-insensitive filter on kode_proyek or nama_proyek
# + return - the dropdown options (max 100), or an error
public function getProyekDropdown(string? search) returns models:ProyekDropdownItem[]|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] parts = [
        `SELECT id, kode_proyek AS "kodeProyek", nama_proyek AS "namaProyek"
         FROM proyek WHERE is_deleted = false`
    ];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        parts.push(` AND (kode_proyek ILIKE ${pattern} OR nama_proyek ILIKE ${pattern})`);
    }
    parts.push(` ORDER BY created_at DESC LIMIT 100`);
    sql:ParameterizedQuery query = sql:queryConcat(...parts);

    models:ProyekDropdownItem[] items =
        check from models:ProyekDropdownItem p in dbc->query(query, models:ProyekDropdownItem)
        select p;
    return items;
}

# Builds the canonical kode_proyek string from its parts. Single source of truth for the format,
# mirrors `nomor_surat_repository:formatNomor`. Reuses `padUrutan` from that same file/module —
# both files live in the `repositories` module, so a module-private function defined in one is
# already visible in the other; no need to redefine it here.
#
# + prefix - the sys_config prefix (e.g. "PRJ")
# + kodeUnit - the unit.kode_unit (e.g. "MKT")
# + tahun - the numbering year
# + urutan - the sequence number within (unit, tahun)
# + return - e.g. "PRJ-MKT-2026-001"
public isolated function formatKodeProyek(string prefix, string kodeUnit, int tahun, int urutan) returns string {
    return string `${prefix}-${kodeUnit}-${tahun}-${padUrutan(urutan)}`;
}
