import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Kategori Finansial Keluar repository =====
#
# Full CRUD access to `kategori_finansial_keluar` (A6) — the master category list referenced by both
# Pembayaran and Pengeluaran Perusahaan. Parameterized `sql:ParameterizedQuery` templates only. This
# table has NO update-audit columns and NO `is_deleted` column: updates rewrite kode/nama/status in
# place, and delete is physical (guarded in the service against rows still referencing it).

# Returns whether an active (status = 'AKTIF') kategori_finansial_keluar with the given id exists.
# Used by the Pembayaran / Pengeluaran finance modules when validating their `kategori_id`.
#
# + id - the kategori_finansial_keluar id to check
# + return - true if an active kategori with that id exists, or an error
public function kategoriFinansialKeluarExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(
        `SELECT count(*) FROM kategori_finansial_keluar WHERE id = ${id} AND status = 'AKTIF'`);
    return count > 0;
}

# Fetches one page of kategori rows matching the optional filters, plus the total count.
#
# + search - optional case-insensitive filter on kode / nama
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findKategoriFinansialKeluar(string? search, string? status, int 'limit, int offset)
        returns record {|models:KategoriFinansialKeluar[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kode ILIKE ${pattern} OR nama ILIKE ${pattern})`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND status = ${status}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, kode, nama, status FROM kategori_finansial_keluar WHERE 1 = 1`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY kode ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:KategoriFinansialKeluar[] items =
        check from models:KategoriFinansialKeluar k in dbc->query(selectQuery, models:KategoriFinansialKeluar)
        select k;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM kategori_finansial_keluar WHERE 1 = 1`];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single kategori row (with audit fields) by id.
#
# + id - the kategori_finansial_keluar id
# + return - the row, `()` if not found, or an error
public function findKategoriFinansialKeluarById(int id) returns models:KategoriFinansialKeluar?|error {
    postgresql:Client dbc = check dbClient();
    models:KategoriFinansialKeluar|sql:Error result = dbc->queryRow(`
        SELECT id, kode, nama, status, created_at::text AS "createdAt", created_by AS "createdBy"
        FROM kategori_finansial_keluar WHERE id = ${id}`, models:KategoriFinansialKeluar);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another kategori already uses the given kode (mirrors uq_kategori_finansial_keluar_kode).
# `excludeId` skips a row (0 on insert; the kategori id on update).
#
# + kode - the code to check
# + excludeId - a kategori id to exclude (0 = none)
# + return - true if a conflicting kode exists, or an error
public function kategoriFinansialKeluarKodeExists(string kode, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM kategori_finansial_keluar WHERE kode = ${kode} AND id <> ${excludeId}`);
    return count > 0;
}

# Inserts a new kategori row and returns the created row.
#
# + kode - unique category code
# + nama - category name
# + status - AKTIF / TIDAK_AKTIF
# + createdBy - the `sub` claim of the caller
# + return - the created row, or an error
public function insertKategoriFinansialKeluar(string kode, string nama, string status, string createdBy)
        returns models:KategoriFinansialKeluar|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO kategori_finansial_keluar (kode, nama, status, created_by)
        VALUES (${kode}, ${nama}, ${status}, ${createdBy})
        RETURNING id`);
    models:KategoriFinansialKeluar? created = check findKategoriFinansialKeluarById(newId);
    if created is () {
        return error("Kategori finansial keluar yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a kategori row (no update-audit columns on this table) and returns the updated row.
#
# + id - the kategori_finansial_keluar id
# + kode - new code
# + nama - new name
# + status - new status
# + return - the updated row, `()` if it does not exist, or an error
public function updateKategoriFinansialKeluar(int id, string kode, string nama, string status)
        returns models:KategoriFinansialKeluar?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE kategori_finansial_keluar SET kode = ${kode}, nama = ${nama}, status = ${status}
        WHERE id = ${id}`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findKategoriFinansialKeluarById(id);
}

# Returns whether the kategori is still referenced by any pembayaran or pengeluaran_perusahaan row
# (guards physical delete). Both tables reference it via `kategori_id`.
#
# + id - the kategori_finansial_keluar id
# + return - true if still referenced, or an error
public function isKategoriFinansialKeluarReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT (SELECT count(*) FROM pembayaran WHERE kategori_id = ${id} AND is_deleted = false)
             + (SELECT count(*) FROM pengeluaran_perusahaan WHERE kategori_id = ${id} AND is_deleted = false)`);
    return count > 0;
}

# Physically deletes a kategori row (this table has no soft-delete column).
#
# + id - the kategori_finansial_keluar id
# + return - true if a row was deleted, false if it did not exist, or an error
public function deleteKategoriFinansialKeluar(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`DELETE FROM kategori_finansial_keluar WHERE id = ${id}`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
