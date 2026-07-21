import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Kategori Surat repository =====
#
# All access to the `kategori_surat` table. Parameterized `sql:ParameterizedQuery` templates
# only. The `is_default` column comes from the v1.7 addendum migration.
#
# Deliberately NOT soft-deleted (unlike most master tables): `nama` carries a plain DB-level
# UNIQUE constraint (`uq_kategori_surat_nama`) with no `is_deleted` in its scope, so a soft-deleted
# row would keep blocking reuse of its name/code forever while looking "available" to the app's
# own existence checks — see `deleteKategoriSurat` for the hard-delete + reference-check pair that
# keeps this consistent.

# Fetches one page of kategori surat matching the optional search filter, plus the total count.
# `search` matches kode OR nama (ILIKE).
#
# + search - optional case-insensitive filter on kode or nama
# + status - optional exact filter on status (AKTIF / TIDAK_AKTIF)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findKategoriSurat(string? search, string? status, int 'limit, int offset)
        returns record {|models:KategoriSurat[] items; int totalItems;|}|error {
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
        `SELECT id, kode, nama, status, is_default AS "isDefault"
         FROM kategori_surat WHERE 1=1`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:KategoriSurat[] items = check from models:KategoriSurat k in dbc->query(selectQuery, models:KategoriSurat)
        select k;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM kategori_surat WHERE 1=1`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single kategori surat (with is_default + audit columns) by id.
#
# + id - the kategori surat id
# + return - the kategori surat, `()` if not found, or an error
public function findKategoriSuratById(int id) returns models:KategoriSurat?|error {
    postgresql:Client dbc = check dbClient();
    models:KategoriSurat|sql:Error result = dbc->queryRow(`
        SELECT id, kode, nama, status, is_default AS "isDefault",
               created_at::text AS "createdAt", updated_at::text AS "updatedAt",
               created_by AS "createdBy", updated_by AS "updatedBy"
        FROM kategori_surat WHERE id = ${id}`, models:KategoriSurat);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another kategori surat already uses the given kode.
# `excludeId` skips a specific row (pass 0 on insert; the target id on update).
#
# + kode - the kode to check
# + excludeId - a kategori surat id to exclude from the check (0 = none)
# + return - true if a conflicting kode exists, or an error
public function kategoriSuratKodeExists(string kode, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM kategori_surat
        WHERE kode = ${kode} AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether another kategori surat already uses the given nama.
#
# + nama - the nama to check
# + excludeId - a kategori surat id to exclude from the check (0 = none)
# + return - true if a conflicting nama exists, or an error
public function kategoriSuratNamaExists(string nama, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM kategori_surat
        WHERE nama = ${nama} AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether this kategori surat is still used by any nomor_surat row, active or not. Checked
# unconditionally (not just `is_deleted = false` rows) because deletion here is a hard DELETE —
# `nomor_surat_kategori_fkey` has no ON DELETE clause, so even a historical/cancelled nomor_surat
# row would otherwise turn a delete into a raw FK-violation error instead of a clean conflict.
#
# + id - the kategori surat id
# + return - true if referenced by any nomor_surat, or an error
public function isKategoriSuratReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM nomor_surat WHERE kategori_surat_id = ${id})`);
    return referenced;
}

# Inserts a new kategori surat and returns the created row. `is_default` is intentionally NOT
# set here — it relies on the column DEFAULT false, so every API-created category is non-default.
#
# + kode - kategori code (validated as DR-XX by the service)
# + nama - kategori name
# + status - AKTIF / TIDAK_AKTIF
# + createdBy - the `sub` claim of the caller
# + return - the created kategori surat, or an error
public function insertKategoriSurat(string kode, string nama, string status, string createdBy)
        returns models:KategoriSurat|error {
    postgresql:Client dbc = check dbClient();
    models:KategoriSurat created = check dbc->queryRow(`
        INSERT INTO kategori_surat (kode, nama, status, created_by)
        VALUES (${kode}, ${nama}, ${status}, ${createdBy})
        RETURNING id, kode, nama, status, is_default AS "isDefault",
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`);
    return created;
}

# Updates a non-deleted kategori surat and returns the updated row. `is_default` is deliberately
# left untouched — it can only be changed via seeding/migration, never through the API.
#
# + id - the kategori surat id
# + kode - new code (validated as DR-XX by the service)
# + nama - new name
# + status - new status (AKTIF / TIDAK_AKTIF)
# + updatedBy - the `sub` claim of the caller
# + return - the updated kategori surat, `()` if the row does not exist, or an error
public function updateKategoriSurat(int id, string kode, string nama, string status, string updatedBy)
        returns models:KategoriSurat?|error {
    postgresql:Client dbc = check dbClient();
    models:KategoriSurat|sql:Error updated = dbc->queryRow(`
        UPDATE kategori_surat SET kode = ${kode}, nama = ${nama}, status = ${status},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id}
        RETURNING id, kode, nama, status, is_default AS "isDefault",
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`, models:KategoriSurat);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Hard-deletes a kategori surat. The caller (`kategori_surat_service:deleteKategoriSurat`) must
# already have confirmed via `isKategoriSuratReferenced` that no nomor_surat row points at this id
# — `nomor_surat_kategori_fkey` has no ON DELETE clause, so a still-referenced row would otherwise
# surface as a raw FK-violation error here.
#
# + id - the kategori surat id
# + return - true if a row was deleted, false if it did not exist, or an error
public function deleteKategoriSurat(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`DELETE FROM kategori_surat WHERE id = ${id}`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
