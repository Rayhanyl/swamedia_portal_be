import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Finansial — Tagihan repository =====
#
# All access to the `tagihan` and `status_tagihan` tables. Parameterized `sql:ParameterizedQuery`
# templates only. List/detail JOIN `proyek` for display fields and compute `totalPencairan` (the
# sum of the tagihan's non-cancelled pencairan) via a correlated subquery — no N+1. Status-change
# logging to `status_tagihan` mirrors `proyek_repository`'s `log_status` handling exactly: the
# initial status is written on insert, and every actual change to `status_aktif` writes a new row
# under the same transaction (with `SELECT ... FOR UPDATE` so a concurrent status change can't race
# past un-logged).

# Fetches one page of non-deleted tagihan matching the optional filters, plus the total count.
# `search` matches no_tagihan (ILIKE).
#
# + search - optional case-insensitive filter on no_tagihan
# + proyekId - optional exact proyek_id filter
# + statusAktif - optional exact status_aktif filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findTagihan(string? search, int? proyekId, string? statusAktif, int 'limit, int offset)
        returns record {|models:Tagihan[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND t.no_tagihan ILIKE ${pattern}`);
    }
    if proyekId is int {
        conditions.push(` AND t.proyek_id = ${proyekId}`);
    }
    if statusAktif is string && statusAktif.trim().length() > 0 {
        conditions.push(` AND t.status_aktif = ${statusAktif}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT t.id, t.proyek_id AS "proyekId", p.kode_proyek AS "proyekKode", p.nama_proyek AS "proyekNama",
                t.tanggal_tagihan::text AS "tanggalTagihan", t.no_tagihan AS "noTagihan", t.keterangan,
                t.status_aktif AS "statusAktif", t.nilai_tagihan AS "nilaiTagihan",
                t.nilai_dpp AS "nilaiDpp", t.ppn, t.pph,
                COALESCE((SELECT SUM(pt.nilai) FROM pencairan_tagihan pt
                          WHERE pt.tagihan_id = t.id AND pt.status IN ('PARSIAL','FINAL')
                            AND pt.is_deleted = false), 0) AS "totalPencairan"
         FROM tagihan t
         JOIN proyek p ON p.id = t.proyek_id
         WHERE t.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY t.id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Tagihan[] items = check from models:Tagihan t in dbc->query(selectQuery, models:Tagihan) select t;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM tagihan t WHERE t.is_deleted = false`];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted tagihan (joined + computed total + audit) by id.
#
# + id - the tagihan id
# + return - the tagihan, `()` if not found (or deleted), or an error
public function findTagihanById(int id) returns models:Tagihan?|error {
    postgresql:Client dbc = check dbClient();
    models:Tagihan|sql:Error result = dbc->queryRow(`
        SELECT t.id, t.proyek_id AS "proyekId", p.kode_proyek AS "proyekKode", p.nama_proyek AS "proyekNama",
               t.tanggal_tagihan::text AS "tanggalTagihan", t.no_tagihan AS "noTagihan", t.keterangan,
               t.status_aktif AS "statusAktif", t.nilai_tagihan AS "nilaiTagihan",
               t.nilai_dpp AS "nilaiDpp", t.ppn, t.pph,
               COALESCE((SELECT SUM(pt.nilai) FROM pencairan_tagihan pt
                         WHERE pt.tagihan_id = t.id AND pt.status IN ('PARSIAL','FINAL')
                           AND pt.is_deleted = false), 0) AS "totalPencairan",
               t.created_at::text AS "createdAt", t.updated_at::text AS "updatedAt",
               t.created_by AS "createdBy", t.updated_by AS "updatedBy"
        FROM tagihan t
        JOIN proyek p ON p.id = t.proyek_id
        WHERE t.id = ${id} AND t.is_deleted = false`, models:Tagihan);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted tagihan already uses the given no_tagihan (mirrors
# `uq_tagihan_no`). `excludeId` skips a row (0 on insert; target id on update).
#
# + noTagihan - the invoice number to check
# + excludeId - a tagihan id to exclude (0 = none)
# + return - true if a conflicting number exists, or an error
public function tagihanNoExists(string noTagihan, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM tagihan
        WHERE no_tagihan = ${noTagihan} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Inserts a new tagihan and its initial `status_tagihan` row atomically, returning the created row.
#
# + proyekId - the owning proyek id
# + tanggalTagihan - the invoice date (YYYY-MM-DD)
# + noTagihan - the unique invoice number
# + keterangan - optional note
# + statusAktif - the initial billing status
# + nilaiTagihan - the invoiced amount
# + nilaiDpp - optional taxable base
# + ppn - optional VAT
# + pph - optional withholding tax
# + createdBy - the `sub` claim of the caller
# + return - the created tagihan, or an error
public function insertTagihan(int proyekId, string tanggalTagihan, string noTagihan, string? keterangan,
        string statusAktif, decimal nilaiTagihan, decimal? nilaiDpp, decimal? ppn, decimal? pph,
        string createdBy) returns models:Tagihan|error {
    postgresql:Client dbc = check dbClient();
    int newId = 0;
    transaction {
        newId = check dbc->queryRow(`
            INSERT INTO tagihan (proyek_id, tanggal_tagihan, no_tagihan, keterangan, status_aktif,
                    nilai_tagihan, nilai_dpp, ppn, pph, created_by)
            VALUES (${proyekId}, ${tanggalTagihan}::date, ${noTagihan}, ${keterangan}, ${statusAktif},
                    ${nilaiTagihan}, ${nilaiDpp}, ${ppn}, ${pph}, ${createdBy})
            RETURNING id`);
        _ = check dbc->execute(`
            INSERT INTO status_tagihan (tagihan_id, status, tanggal, keterangan, created_by)
            VALUES (${newId}, ${statusAktif}, ${tanggalTagihan}::date, 'Status awal saat tagihan dibuat', ${createdBy})`);
        check commit;
    }
    models:Tagihan? created = check findTagihanById(newId);
    if created is () {
        return error("Tagihan yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted tagihan and, whenever `status_aktif` actually changes, writes a
# `status_tagihan` log row — all under one transaction (reads the current status with `FOR UPDATE`
# so a concurrent status change can't slip past un-logged), mirroring `updateProyek`.
#
# + id - the tagihan id
# + proyekId - new owning proyek id
# + tanggalTagihan - new invoice date
# + noTagihan - new invoice number
# + keterangan - new note, or () to clear it
# + statusAktif - new billing status
# + statusKomentar - optional note recorded on the status_tagihan row (only when status changed)
# + nilaiTagihan - new invoiced amount
# + nilaiDpp - new taxable base, or () to clear it
# + ppn - new VAT, or () to clear it
# + pph - new withholding tax, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was deleted), or an error
public function updateTagihan(int id, int proyekId, string tanggalTagihan, string noTagihan,
        string? keterangan, string statusAktif, string? statusKomentar, decimal nilaiTagihan,
        decimal? nilaiDpp, decimal? ppn, decimal? pph, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean found = false;
    transaction {
        record {|string statusAktif;|}|sql:Error current = dbc->queryRow(
            `SELECT status_aktif AS "statusAktif" FROM tagihan WHERE id = ${id} AND is_deleted = false FOR UPDATE`);
        if current is sql:NoRowsError {
            check commit;
        } else {
            record {|string statusAktif;|} row = check current;
            found = true;

            _ = check dbc->execute(`
                UPDATE tagihan SET proyek_id = ${proyekId}, tanggal_tagihan = ${tanggalTagihan}::date,
                       no_tagihan = ${noTagihan}, keterangan = ${keterangan}, status_aktif = ${statusAktif},
                       nilai_tagihan = ${nilaiTagihan}, nilai_dpp = ${nilaiDpp}, ppn = ${ppn}, pph = ${pph},
                       updated_by = ${updatedBy}, updated_at = now()
                WHERE id = ${id}`);

            if row.statusAktif != statusAktif {
                _ = check dbc->execute(`
                    INSERT INTO status_tagihan (tagihan_id, status, tanggal, keterangan, created_by)
                    VALUES (${id}, ${statusAktif}, CURRENT_DATE, ${statusKomentar}, ${updatedBy})`);
            }
            check commit;
        }
    }
    return found;
}

# Soft-deletes a tagihan (sets is_deleted = true). Never physically deletes.
#
# + id - the tagihan id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteTagihan(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE tagihan SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}

# Fetches the full status-transition history of a tagihan, newest first.
#
# + tagihanId - the tagihan id
# + return - the status_tagihan rows, or an error
public function findTagihanStatusHistory(int tagihanId) returns models:TagihanStatusHistory[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:TagihanStatusHistory s in dbc->query(`
            SELECT id, tagihan_id AS "tagihanId", status, tanggal::text AS "tanggal", keterangan,
                   created_at::text AS "createdAt", created_by AS "createdBy"
            FROM status_tagihan
            WHERE tagihan_id = ${tagihanId} AND is_deleted = false
            ORDER BY tanggal DESC, id DESC`, models:TagihanStatusHistory)
        select s;
}

# Returns whether a non-deleted tagihan with the given id exists (used by the Pencairan module to
# validate its parent).
#
# + id - the tagihan id
# + return - true if an active tagihan with that id exists, or an error
public function tagihanExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM tagihan WHERE id = ${id} AND is_deleted = false`);
    return count > 0;
}
