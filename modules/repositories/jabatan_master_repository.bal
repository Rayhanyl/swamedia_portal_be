import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Jabatan (jabatan_master) repository =====
#
# All access to the `jabatan_master` table. Read-only from the API's perspective — the
# contract has no create/update/delete for this master, only the dropdown list and the
# FK-lookup/existence checks consumed by karyawan_repository/karyawan_service. Note the
# table has no `is_deleted` column (unlike the other masters) — only `status`.

# Fetches jabatan_master rows matching the optional search/status filters, unpaginated
# (flat list — this is a dropdown source, not a paginated list endpoint).
#
# + search - optional ILIKE filter on nama_jabatan
# + status - optional exact filter on status (AKTIF / TIDAK_AKTIF); () defaults to AKTIF only
# + return - the matching jabatan rows, or an error
public function findJabatan(string? search, string? status) returns models:JabatanMaster[]|error {
    postgresql:Client dbc = check dbClient();

    string effectiveStatus = status is string && status.trim().length() > 0 ? status.trim() : "AKTIF";

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, nama_jabatan AS "namaJabatan", kategori, unit_terkait_id AS "unitTerkaitId",
                is_kombinasi_unit AS "isKombinasiUnit", status
         FROM jabatan_master WHERE status = ${effectiveStatus}`
    ];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        selectParts.push(` AND nama_jabatan ILIKE ${pattern}`);
    }
    selectParts.push(` ORDER BY nama_jabatan ASC`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    return from models:JabatanMaster j in dbc->query(selectQuery, models:JabatanMaster)
        select j;
}

# Fetches the compact {id, namaJabatan, kategori} projection of a single jabatan_master row,
# for embedding into Karyawan list/detail responses (`JabatanRef`).
#
# + id - the jabatan_master id
# + return - the JabatanRef, `()` if not found, or an error
public function findJabatanRefById(int id) returns models:JabatanRef?|error {
    postgresql:Client dbc = check dbClient();
    models:JabatanRef|sql:Error result = dbc->queryRow(`
        SELECT id, nama_jabatan AS "namaJabatan", kategori
        FROM jabatan_master WHERE id = ${id}`, models:JabatanRef);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether an AKTIF jabatan_master row with the given id exists (used to validate
# karyawan.jabatan_id on create/update).
#
# + id - the jabatan_master id to check
# + return - true if an AKTIF jabatan with that id exists, or an error
public function jabatanExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM jabatan_master WHERE id = ${id} AND status = 'AKTIF'`);
    return count > 0;
}
