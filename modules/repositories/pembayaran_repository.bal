import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Finansial — Pembayaran repository =====
#
# All access to the `pembayaran` table (project-tied cash-out with an approval workflow).
# Parameterized `sql:ParameterizedQuery` templates only. List/detail JOIN `proyek` and
# `kategori_finansial_keluar` for display fields (no N+1). Editing a row resets it to PENGAJUAN and
# clears the approval fields (the service only permits edits while PENGAJUAN/REJECTED); `approve`/
# `reject` are dedicated transitions that stamp `approved_by`/`approved_at`.

# Fetches one page of non-deleted pembayaran matching the optional filters, plus the total count.
# `search` matches keterangan or the joined proyek code/name (ILIKE).
#
# + search - optional case-insensitive filter on keterangan / proyek code / proyek name
# + proyekId - optional exact proyek_id filter
# + kategoriId - optional exact kategori_id filter
# + status - optional exact status filter (PENGAJUAN / APPROVED / REJECTED)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findPembayaran(string? search, int? proyekId, int? kategoriId, string? status,
        int 'limit, int offset) returns record {|models:Pembayaran[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(
            ` AND (pb.keterangan ILIKE ${pattern} OR p.kode_proyek ILIKE ${pattern} OR p.nama_proyek ILIKE ${pattern})`);
    }
    if proyekId is int {
        conditions.push(` AND pb.proyek_id = ${proyekId}`);
    }
    if kategoriId is int {
        conditions.push(` AND pb.kategori_id = ${kategoriId}`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND pb.status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT pb.id, pb.proyek_id AS "proyekId", p.kode_proyek AS "proyekKode", p.nama_proyek AS "proyekNama",
                pb.kategori_id AS "kategoriId", kf.nama AS "kategoriNama", pb.nilai,
                pb.tanggal_pengajuan::text AS "tanggalPengajuan", pb.tanggal_realisasi::text AS "tanggalRealisasi",
                pb.keterangan, pb.status, pb.approved_by AS "approvedBy", pb.approved_at::text AS "approvedAt",
                pb.catatan_approval AS "catatanApproval"
         FROM pembayaran pb
         JOIN proyek p ON p.id = pb.proyek_id
         JOIN kategori_finansial_keluar kf ON kf.id = pb.kategori_id
         WHERE pb.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY pb.id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Pembayaran[] items = check from models:Pembayaran pb in dbc->query(selectQuery, models:Pembayaran)
        select pb;

    sql:ParameterizedQuery[] countParts = [
        `SELECT count(*) FROM pembayaran pb JOIN proyek p ON p.id = pb.proyek_id WHERE pb.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted pembayaran (joined + audit) by id.
#
# + id - the pembayaran id
# + return - the pembayaran, `()` if not found (or deleted), or an error
public function findPembayaranById(int id) returns models:Pembayaran?|error {
    postgresql:Client dbc = check dbClient();
    models:Pembayaran|sql:Error result = dbc->queryRow(`
        SELECT pb.id, pb.proyek_id AS "proyekId", p.kode_proyek AS "proyekKode", p.nama_proyek AS "proyekNama",
               pb.kategori_id AS "kategoriId", kf.nama AS "kategoriNama", pb.nilai,
               pb.tanggal_pengajuan::text AS "tanggalPengajuan", pb.tanggal_realisasi::text AS "tanggalRealisasi",
               pb.keterangan, pb.status, pb.approved_by AS "approvedBy", pb.approved_at::text AS "approvedAt",
               pb.catatan_approval AS "catatanApproval",
               pb.created_at::text AS "createdAt", pb.updated_at::text AS "updatedAt",
               pb.created_by AS "createdBy", pb.updated_by AS "updatedBy"
        FROM pembayaran pb
        JOIN proyek p ON p.id = pb.proyek_id
        JOIN kategori_finansial_keluar kf ON kf.id = pb.kategori_id
        WHERE pb.id = ${id} AND pb.is_deleted = false`, models:Pembayaran);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Inserts a new pembayaran (status defaults to PENGAJUAN) and returns the created row.
#
# + proyekId - the proyek this payment is tied to
# + kategoriId - the kategori_finansial_keluar id
# + nilai - the payment amount
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - optional actual cash-out date
# + keterangan - optional note
# + createdBy - the `sub` claim of the caller
# + return - the created pembayaran, or an error
public function insertPembayaran(int proyekId, int kategoriId, decimal nilai, string tanggalPengajuan,
        string? tanggalRealisasi, string? keterangan, string createdBy) returns models:Pembayaran|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO pembayaran (proyek_id, kategori_id, nilai, tanggal_pengajuan, tanggal_realisasi,
                keterangan, created_by)
        VALUES (${proyekId}, ${kategoriId}, ${nilai}, ${tanggalPengajuan}::date, ${tanggalRealisasi}::date,
                ${keterangan}, ${createdBy})
        RETURNING id`);
    models:Pembayaran? created = check findPembayaranById(newId);
    if created is () {
        return error("Pembayaran yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted pembayaran and RESETS it to PENGAJUAN, clearing the approval fields — an
# edit re-opens the request for approval (schema implementation note #5). The service guarantees
# this is only called while the row is PENGAJUAN/REJECTED (an APPROVED row is locked).
#
# + id - the pembayaran id
# + proyekId - new proyek id
# + kategoriId - new kategori id
# + nilai - new amount
# + tanggalPengajuan - new request date
# + tanggalRealisasi - new realization date, or () to clear it
# + keterangan - new note, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - the updated pembayaran, `()` if it does not exist (or is deleted), or an error
public function updatePembayaran(int id, int proyekId, int kategoriId, decimal nilai, string tanggalPengajuan,
        string? tanggalRealisasi, string? keterangan, string updatedBy) returns models:Pembayaran?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pembayaran SET proyek_id = ${proyekId}, kategori_id = ${kategoriId}, nilai = ${nilai},
               tanggal_pengajuan = ${tanggalPengajuan}::date, tanggal_realisasi = ${tanggalRealisasi}::date,
               keterangan = ${keterangan}, status = 'PENGAJUAN',
               approved_by = NULL, approved_at = NULL, catatan_approval = NULL,
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findPembayaranById(id);
}

# Approves a pembayaran that is currently PENGAJUAN: sets status APPROVED, stamps approver + time,
# records the optional approval note, and sets the realization date when one is supplied (keeps the
# existing one otherwise). Scoped to `status = 'PENGAJUAN'` so an already-decided row is untouched.
#
# + id - the pembayaran id
# + approvedBy - the approver's `sub` claim
# + tanggalRealisasi - optional realization date to set on approval
# + catatan - optional approval note
# + return - the updated pembayaran, `()` if it did not exist / was not PENGAJUAN, or an error
public function approvePembayaran(int id, string approvedBy, string? tanggalRealisasi, string? catatan)
        returns models:Pembayaran?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pembayaran SET status = 'APPROVED', approved_by = ${approvedBy}, approved_at = now(),
               catatan_approval = ${catatan},
               tanggal_realisasi = COALESCE(${tanggalRealisasi}::date, tanggal_realisasi),
               updated_by = ${approvedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false AND status = 'PENGAJUAN'`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findPembayaranById(id);
}

# Rejects a pembayaran that is currently PENGAJUAN: sets status REJECTED, stamps approver + time, and
# records the optional rejection note. Scoped to `status = 'PENGAJUAN'`.
#
# + id - the pembayaran id
# + approvedBy - the rejecter's `sub` claim
# + catatan - optional rejection note
# + return - the updated pembayaran, `()` if it did not exist / was not PENGAJUAN, or an error
public function rejectPembayaran(int id, string approvedBy, string? catatan) returns models:Pembayaran?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pembayaran SET status = 'REJECTED', approved_by = ${approvedBy}, approved_at = now(),
               catatan_approval = ${catatan}, updated_by = ${approvedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false AND status = 'PENGAJUAN'`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findPembayaranById(id);
}

# Soft-deletes a pembayaran (sets is_deleted = true). Never physically deletes.
#
# + id - the pembayaran id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeletePembayaran(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pembayaran SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
