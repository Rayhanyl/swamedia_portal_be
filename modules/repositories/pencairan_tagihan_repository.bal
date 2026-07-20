import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Finansial — Pencairan Tagihan repository =====
#
# All access to the `pencairan_tagihan` table (staged cash-in realization of a tagihan).
# Parameterized `sql:ParameterizedQuery` templates only. Every read/mutation is scoped to a
# `tagihan_id` so a pencairan id from one tagihan can never be operated on through another tagihan's
# path. This table has no update-audit columns (created_at/created_by only) but does have
# `is_deleted` (soft delete). Only PARSIAL/FINAL rows count toward the tagihan's realized total —
# DIBATALKAN (cancelled) rows are excluded.

# Lists all non-deleted pencairan of a tagihan, newest first.
#
# + tagihanId - the owning tagihan id
# + return - the pencairan rows, or an error
public function findPencairanByTagihan(int tagihanId) returns models:PencairanTagihan[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:PencairanTagihan p in dbc->query(`
            SELECT id, tagihan_id AS "tagihanId", tanggal_pencairan::text AS "tanggalPencairan",
                   nilai, status, keterangan, created_at::text AS "createdAt", created_by AS "createdBy"
            FROM pencairan_tagihan
            WHERE tagihan_id = ${tagihanId} AND is_deleted = false
            ORDER BY tanggal_pencairan DESC, id DESC`, models:PencairanTagihan)
        select p;
}

# Fetches a single non-deleted pencairan by id AND owning tagihan.
#
# + id - the pencairan id
# + tagihanId - the tagihan the pencairan must belong to
# + return - the pencairan, `()` if not found (wrong tagihan/deleted), or an error
public function findPencairanById(int id, int tagihanId) returns models:PencairanTagihan?|error {
    postgresql:Client dbc = check dbClient();
    models:PencairanTagihan|sql:Error result = dbc->queryRow(`
        SELECT id, tagihan_id AS "tagihanId", tanggal_pencairan::text AS "tanggalPencairan",
               nilai, status, keterangan, created_at::text AS "createdAt", created_by AS "createdBy"
        FROM pencairan_tagihan
        WHERE id = ${id} AND tagihan_id = ${tagihanId} AND is_deleted = false`, models:PencairanTagihan);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Sums the non-cancelled (PARSIAL/FINAL) pencairan of a tagihan, optionally excluding one row — used
# to check the total never exceeds the tagihan's `nilai_tagihan`. `excludeId` skips a row (0 to sum
# all; the target id on update so the row being replaced isn't double-counted).
#
# + tagihanId - the tagihan id
# + excludeId - a pencairan id to exclude (0 = none)
# + return - the summed nilai (0 when none), or an error
public function sumActivePencairan(int tagihanId, int excludeId) returns decimal|error {
    postgresql:Client dbc = check dbClient();
    decimal total = check dbc->queryRow(`
        SELECT COALESCE(SUM(nilai), 0) FROM pencairan_tagihan
        WHERE tagihan_id = ${tagihanId} AND status IN ('PARSIAL','FINAL') AND is_deleted = false
              AND id <> ${excludeId}`);
    return total;
}

# Inserts a new pencairan and returns the created row.
#
# + tagihanId - the owning tagihan id
# + tanggalPencairan - the disbursement date (YYYY-MM-DD)
# + nilai - the disbursed amount
# + status - PARSIAL / FINAL / DIBATALKAN
# + keterangan - optional note
# + createdBy - the `sub` claim of the caller
# + return - the created pencairan, or an error
public function insertPencairan(int tagihanId, string tanggalPencairan, decimal nilai, string status,
        string? keterangan, string createdBy) returns models:PencairanTagihan|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO pencairan_tagihan (tagihan_id, tanggal_pencairan, nilai, status, keterangan, created_by)
        VALUES (${tagihanId}, ${tanggalPencairan}::date, ${nilai}, ${status}, ${keterangan}, ${createdBy})
        RETURNING id`);
    models:PencairanTagihan? created = check findPencairanById(newId, tagihanId);
    if created is () {
        return error("Pencairan yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted pencairan (scoped to its tagihan) and returns the updated row. The table has
# no update-audit columns, so nothing records who edited it.
#
# + id - the pencairan id
# + tagihanId - the tagihan the pencairan must belong to
# + tanggalPencairan - new disbursement date
# + nilai - new disbursed amount
# + status - new status
# + keterangan - new note, or () to clear it
# + return - the updated pencairan, `()` if it does not exist (wrong tagihan/deleted), or an error
public function updatePencairan(int id, int tagihanId, string tanggalPencairan, decimal nilai,
        string status, string? keterangan) returns models:PencairanTagihan?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pencairan_tagihan SET tanggal_pencairan = ${tanggalPencairan}::date, nilai = ${nilai},
               status = ${status}, keterangan = ${keterangan}
        WHERE id = ${id} AND tagihan_id = ${tagihanId} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findPencairanById(id, tagihanId);
}

# Soft-deletes a pencairan (sets is_deleted = true). Never physically deletes.
#
# + id - the pencairan id
# + tagihanId - the tagihan the pencairan must belong to
# + return - true if a row was updated, false if it did not exist (wrong tagihan/deleted), or an error
public function softDeletePencairan(int id, int tagihanId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE pencairan_tagihan SET is_deleted = true
        WHERE id = ${id} AND tagihan_id = ${tagihanId} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
