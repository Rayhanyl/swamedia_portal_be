import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Finansial — Pengeluaran Perusahaan repository =====
#
# All access to the `pengeluaran_perusahaan` table (unit-tied internal cash-out with an approval
# workflow — structurally the twin of `pembayaran`, only keyed on `unit_id` instead of `proyek_id`).
# Parameterized `sql:ParameterizedQuery` templates only. List/detail JOIN `unit` and
# `kategori_finansial_keluar` for display fields. Same edit-resets-to-PENGAJUAN and approve/reject
# semantics as pembayaran.

# Fetches one page of non-deleted pengeluaran matching the optional filters, plus the total count.
# `search` matches keterangan or the joined unit name (ILIKE).
#
# + search - optional case-insensitive filter on keterangan / unit name
# + unitId - optional exact unit_id filter
# + kategoriId - optional exact kategori_id filter
# + status - optional exact status filter (PENGAJUAN / APPROVED / REJECTED)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findPengeluaran(string? search, int? unitId, int? kategoriId, string? status,
        int 'limit, int offset) returns record {|models:PengeluaranPerusahaan[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (pg.keterangan ILIKE ${pattern} OR u.nama_unit ILIKE ${pattern})`);
    }
    if unitId is int {
        conditions.push(` AND pg.unit_id = ${unitId}`);
    }
    if kategoriId is int {
        conditions.push(` AND pg.kategori_id = ${kategoriId}`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND pg.status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT pg.id, pg.unit_id AS "unitId", u.nama_unit AS "unitNama",
                pg.kategori_id AS "kategoriId", kf.nama AS "kategoriNama", pg.nilai,
                pg.tanggal_pengajuan::text AS "tanggalPengajuan", pg.tanggal_realisasi::text AS "tanggalRealisasi",
                pg.keterangan, pg.status, pg.approved_by AS "approvedBy", pg.approved_at::text AS "approvedAt",
                pg.catatan_approval AS "catatanApproval"
         FROM pengeluaran_perusahaan pg
         JOIN unit u ON u.id = pg.unit_id
         JOIN kategori_finansial_keluar kf ON kf.id = pg.kategori_id
         WHERE pg.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY pg.id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:PengeluaranPerusahaan[] items =
        check from models:PengeluaranPerusahaan pg in dbc->query(selectQuery, models:PengeluaranPerusahaan)
        select pg;

    sql:ParameterizedQuery[] countParts = [
        `SELECT count(*) FROM pengeluaran_perusahaan pg JOIN unit u ON u.id = pg.unit_id
         WHERE pg.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted pengeluaran (joined + audit) by id.
#
# + id - the pengeluaran id
# + return - the pengeluaran, `()` if not found (or deleted), or an error
public function findPengeluaranById(int id) returns models:PengeluaranPerusahaan?|error {
    postgresql:Client dbc = check dbClient();
    models:PengeluaranPerusahaan|sql:Error result = dbc->queryRow(`
        SELECT pg.id, pg.unit_id AS "unitId", u.nama_unit AS "unitNama",
               pg.kategori_id AS "kategoriId", kf.nama AS "kategoriNama", pg.nilai,
               pg.tanggal_pengajuan::text AS "tanggalPengajuan", pg.tanggal_realisasi::text AS "tanggalRealisasi",
               pg.keterangan, pg.status, pg.approved_by AS "approvedBy", pg.approved_at::text AS "approvedAt",
               pg.catatan_approval AS "catatanApproval",
               pg.created_at::text AS "createdAt", pg.updated_at::text AS "updatedAt",
               pg.created_by AS "createdBy", pg.updated_by AS "updatedBy"
        FROM pengeluaran_perusahaan pg
        JOIN unit u ON u.id = pg.unit_id
        JOIN kategori_finansial_keluar kf ON kf.id = pg.kategori_id
        WHERE pg.id = ${id} AND pg.is_deleted = false`, models:PengeluaranPerusahaan);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Inserts a new pengeluaran (status defaults to PENGAJUAN) and returns the created row.
#
# + unitId - the unit this expense belongs to
# + kategoriId - the kategori_finansial_keluar id
# + nilai - the expense amount
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - optional actual cash-out date
# + keterangan - optional note
# + createdBy - the `sub` claim of the caller
# + return - the created pengeluaran, or an error
public function insertPengeluaran(int unitId, int kategoriId, decimal nilai, string tanggalPengajuan,
        string? tanggalRealisasi, string? keterangan, string createdBy)
        returns models:PengeluaranPerusahaan|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO pengeluaran_perusahaan (unit_id, kategori_id, nilai, tanggal_pengajuan, tanggal_realisasi,
                keterangan, created_by)
        VALUES (${unitId}, ${kategoriId}, ${nilai}, ${tanggalPengajuan}::date, ${tanggalRealisasi}::date,
                ${keterangan}, ${createdBy})
        RETURNING id`);
    models:PengeluaranPerusahaan? created = check findPengeluaranById(newId);
    if created is () {
        return error("Pengeluaran yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted pengeluaran and RESETS it to PENGAJUAN, clearing the approval fields (schema
# implementation note #5). The service guarantees this is only called while PENGAJUAN/REJECTED.
#
# + id - the pengeluaran id
# + unitId - new unit id
# + kategoriId - new kategori id
# + nilai - new amount
# + tanggalPengajuan - new request date
# + tanggalRealisasi - new realization date, or () to clear it
# + keterangan - new note, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - the updated pengeluaran, `()` if it does not exist (or is deleted), or an error
public function updatePengeluaran(int id, int unitId, int kategoriId, decimal nilai, string tanggalPengajuan,
        string? tanggalRealisasi, string? keterangan, string updatedBy)
        returns models:PengeluaranPerusahaan?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pengeluaran_perusahaan SET unit_id = ${unitId}, kategori_id = ${kategoriId}, nilai = ${nilai},
               tanggal_pengajuan = ${tanggalPengajuan}::date, tanggal_realisasi = ${tanggalRealisasi}::date,
               keterangan = ${keterangan}, status = 'PENGAJUAN',
               approved_by = NULL, approved_at = NULL, catatan_approval = NULL,
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findPengeluaranById(id);
}

# Approves a pengeluaran that is currently PENGAJUAN (see `pembayaran_repository:approvePembayaran`
# for the identical semantics).
#
# + id - the pengeluaran id
# + approvedBy - the approver's `sub` claim
# + tanggalRealisasi - optional realization date to set on approval
# + catatan - optional approval note
# + return - the updated pengeluaran, `()` if it did not exist / was not PENGAJUAN, or an error
public function approvePengeluaran(int id, string approvedBy, string? tanggalRealisasi, string? catatan)
        returns models:PengeluaranPerusahaan?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pengeluaran_perusahaan SET status = 'APPROVED', approved_by = ${approvedBy}, approved_at = now(),
               catatan_approval = ${catatan},
               tanggal_realisasi = COALESCE(${tanggalRealisasi}::date, tanggal_realisasi),
               updated_by = ${approvedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false AND status = 'PENGAJUAN'`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findPengeluaranById(id);
}

# Rejects a pengeluaran that is currently PENGAJUAN (see `pembayaran_repository:rejectPembayaran`).
#
# + id - the pengeluaran id
# + approvedBy - the rejecter's `sub` claim
# + catatan - optional rejection note
# + return - the updated pengeluaran, `()` if it did not exist / was not PENGAJUAN, or an error
public function rejectPengeluaran(int id, string approvedBy, string? catatan)
        returns models:PengeluaranPerusahaan?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pengeluaran_perusahaan SET status = 'REJECTED', approved_by = ${approvedBy}, approved_at = now(),
               catatan_approval = ${catatan}, updated_by = ${approvedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false AND status = 'PENGAJUAN'`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findPengeluaranById(id);
}

# Soft-deletes a pengeluaran (sets is_deleted = true). Never physically deletes.
#
# + id - the pengeluaran id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeletePengeluaran(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pengeluaran_perusahaan SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
