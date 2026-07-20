import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Kontrak Payung repository =====
#
# All access to the `kontrak_payung` table and its `kontrak_payung_harga_role` child (per-role price
# lines). Parameterized `sql:ParameterizedQuery` templates only. List/detail JOIN `customer` to
# resolve `customerNama` in a single query (no N+1); price lines JOIN `project_role_master` for
# `roleNama`. The child table has no soft-delete/update-audit columns, so its rows are managed
# together with the parent: inserted with the contract on create, and replaced wholesale (physical
# delete + re-insert, inside one transaction) on update.

# Fetches one page of non-deleted kontrak payung matching the optional filters, plus the total
# count. `search` matches no_kontrak_payung OR nama_kontrak (ILIKE). The list projection omits the
# price lines (detail only).
#
# + search - optional case-insensitive filter on no_kontrak_payung or nama_kontrak
# + customerId - optional exact customer_id filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findKontrakPayung(string? search, int? customerId, int 'limit, int offset)
        returns record {|models:KontrakPayung[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kp.no_kontrak_payung ILIKE ${pattern} OR kp.nama_kontrak ILIKE ${pattern})`);
    }
    if customerId is int {
        conditions.push(` AND kp.customer_id = ${customerId}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT kp.id, kp.customer_id AS "customerId", c.nama AS "customerNama",
                kp.no_kontrak_payung AS "noKontrakPayung", kp.nama_kontrak AS "namaKontrak",
                kp.tanggal_kontrak::text AS "tanggalKontrak", kp.tanggal_mulai::text AS "tanggalMulai",
                kp.tanggal_selesai::text AS "tanggalSelesai"
         FROM kontrak_payung kp
         JOIN customer c ON c.id = kp.customer_id
         WHERE kp.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY kp.id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:KontrakPayung[] items = check from models:KontrakPayung k in dbc->query(selectQuery, models:KontrakPayung)
        select k;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM kontrak_payung kp WHERE kp.is_deleted = false`];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted kontrak payung by id, with its per-role price lines and audit columns.
#
# + id - the kontrak payung id
# + return - the contract (with `hargaRole` populated), `()` if not found (or deleted), or an error
public function findKontrakPayungById(int id) returns models:KontrakPayung?|error {
    postgresql:Client dbc = check dbClient();
    models:KontrakPayung|sql:Error result = dbc->queryRow(`
        SELECT kp.id, kp.customer_id AS "customerId", c.nama AS "customerNama",
               kp.no_kontrak_payung AS "noKontrakPayung", kp.nama_kontrak AS "namaKontrak",
               kp.tanggal_kontrak::text AS "tanggalKontrak", kp.tanggal_mulai::text AS "tanggalMulai",
               kp.tanggal_selesai::text AS "tanggalSelesai",
               kp.created_at::text AS "createdAt", kp.updated_at::text AS "updatedAt",
               kp.created_by AS "createdBy", kp.updated_by AS "updatedBy"
        FROM kontrak_payung kp
        JOIN customer c ON c.id = kp.customer_id
        WHERE kp.id = ${id} AND kp.is_deleted = false`, models:KontrakPayung);
    if result is sql:NoRowsError {
        return ();
    }
    models:KontrakPayung kontrak = check result;
    kontrak.hargaRole = check findKontrakPayungHargaRole(id);
    return kontrak;
}

# Fetches the per-role price lines of a kontrak payung (with joined role name), ordered by id.
#
# + kontrakPayungId - the owning kontrak payung id
# + return - the price lines, or an error
public function findKontrakPayungHargaRole(int kontrakPayungId) returns models:KontrakPayungHargaRole[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:KontrakPayungHargaRole h in dbc->query(`
            SELECT hr.id, hr.kontrak_payung_id AS "kontrakPayungId", hr.role_id AS "roleId",
                   pr.nama_role AS "roleNama", hr.tipe_harga AS "tipeHarga", hr.nilai, hr.keterangan
            FROM kontrak_payung_harga_role hr
            JOIN project_role_master pr ON pr.id = hr.role_id
            WHERE hr.kontrak_payung_id = ${kontrakPayungId}
            ORDER BY hr.id ASC`, models:KontrakPayungHargaRole)
        select h;
}

# Returns whether another non-deleted kontrak payung already uses the given no_kontrak_payung
# (mirrors `uq_kontrak_payung_no` as a friendly pre-check). `excludeId` skips a row (0 on insert;
# target id on update).
#
# + noKontrakPayung - the contract number to check
# + excludeId - a kontrak payung id to exclude (0 = none)
# + return - true if a conflicting number exists, or an error
public function kontrakPayungNoExists(string noKontrakPayung, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM kontrak_payung
        WHERE no_kontrak_payung = ${noKontrakPayung} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether any non-deleted proyek or kontrak_biasa still references this kontrak payung —
# used to block deletion of a contract that is still in use.
#
# + id - the kontrak payung id
# + return - true if referenced, or an error
public function isKontrakPayungReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(`
        SELECT EXISTS(SELECT 1 FROM proyek WHERE kontrak_payung_id = ${id} AND is_deleted = false)
            OR EXISTS(SELECT 1 FROM kontrak_biasa WHERE kontrak_payung_id = ${id} AND is_deleted = false)`);
    return referenced;
}

# Returns the owning customer_id of a non-deleted kontrak_payung row — used to validate that a
# proyek's optional kontrak_payung_id actually belongs to the same customer as the proyek. Moved
# here from proyek_repository now that the Kontrak Payung module exists (proyek_service still calls
# this by name — functions are module-scoped, not file-scoped, so nothing else needed to change).
#
# + id - the kontrak_payung id
# + return - its customer_id, `()` if not found (or deleted), or an error
public function kontrakPayungCustomerId(int id) returns int?|error {
    postgresql:Client dbc = check dbClient();
    record {|int customerId;|}|sql:Error row = dbc->queryRow(
        `SELECT customer_id AS "customerId" FROM kontrak_payung WHERE id = ${id} AND is_deleted = false`);
    if row is sql:NoRowsError {
        return ();
    }
    if row is sql:Error {
        return row;
    }
    return row.customerId;
}

# Inserts a new kontrak payung and its price lines atomically, returning the created row (assembled
# with its `hargaRole`).
#
# + customerId - the owning customer
# + noKontrakPayung - the unique contract number
# + namaKontrak - the contract name
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + tanggalMulai - the coverage start date (YYYY-MM-DD)
# + tanggalSelesai - the coverage end date (YYYY-MM-DD)
# + hargaRole - the (already validated) per-role price lines to attach
# + createdBy - the `sub` claim of the caller
# + return - the created contract, or an error
public function insertKontrakPayung(int customerId, string noKontrakPayung, string namaKontrak,
        string tanggalKontrak, string tanggalMulai, string tanggalSelesai,
        models:KontrakPayungHargaRoleInput[] hargaRole, string createdBy) returns models:KontrakPayung|error {
    postgresql:Client dbc = check dbClient();
    int newId = 0;
    transaction {
        newId = check dbc->queryRow(`
            INSERT INTO kontrak_payung (customer_id, no_kontrak_payung, nama_kontrak, tanggal_kontrak,
                    tanggal_mulai, tanggal_selesai, created_by)
            VALUES (${customerId}, ${noKontrakPayung}, ${namaKontrak}, ${tanggalKontrak}::date,
                    ${tanggalMulai}::date, ${tanggalSelesai}::date, ${createdBy})
            RETURNING id`);
        check insertHargaRoleLines(dbc, newId, hargaRole, createdBy);
        check commit;
    }
    models:KontrakPayung? created = check findKontrakPayungById(newId);
    if created is () {
        return error("Kontrak payung yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted kontrak payung and, when `replaceHargaRole` is true, replaces its price
# lines (delete-all + re-insert) — all in one transaction. When `replaceHargaRole` is false the
# existing price lines are left untouched. Returns the updated row (assembled with its `hargaRole`),
# or `()` if the contract does not exist (or is deleted).
#
# + id - the kontrak payung id
# + customerId - new owning customer
# + noKontrakPayung - new contract number
# + namaKontrak - new contract name
# + tanggalKontrak - new contract date (YYYY-MM-DD)
# + tanggalMulai - new coverage start date (YYYY-MM-DD)
# + tanggalSelesai - new coverage end date (YYYY-MM-DD)
# + replaceHargaRole - whether to replace the price lines with `hargaRole`
# + hargaRole - the replacement price lines (ignored when `replaceHargaRole` is false)
# + updatedBy - the `sub` claim of the caller
# + return - the updated contract, `()` if it does not exist (or is deleted), or an error
public function updateKontrakPayung(int id, int customerId, string noKontrakPayung, string namaKontrak,
        string tanggalKontrak, string tanggalMulai, string tanggalSelesai, boolean replaceHargaRole,
        models:KontrakPayungHargaRoleInput[] hargaRole, string updatedBy) returns models:KontrakPayung?|error {
    postgresql:Client dbc = check dbClient();
    boolean found = false;
    transaction {
        sql:ExecutionResult result = check dbc->execute(`
            UPDATE kontrak_payung SET customer_id = ${customerId}, no_kontrak_payung = ${noKontrakPayung},
                   nama_kontrak = ${namaKontrak}, tanggal_kontrak = ${tanggalKontrak}::date,
                   tanggal_mulai = ${tanggalMulai}::date, tanggal_selesai = ${tanggalSelesai}::date,
                   updated_by = ${updatedBy}, updated_at = now()
            WHERE id = ${id} AND is_deleted = false`);
        int? affected = result.affectedRowCount;
        found = affected is int && affected > 0;
        if found && replaceHargaRole {
            _ = check dbc->execute(`DELETE FROM kontrak_payung_harga_role WHERE kontrak_payung_id = ${id}`);
            check insertHargaRoleLines(dbc, id, hargaRole, updatedBy);
        }
        check commit;
    }
    if !found {
        return ();
    }
    return findKontrakPayungById(id);
}

# Inserts a batch of price lines for a contract. Shared by insert/update; runs inside the caller's
# transaction.
#
# + dbc - the DB client bound to the enclosing transaction
# + kontrakPayungId - the owning contract id
# + hargaRole - the price lines to insert
# + createdBy - the `sub` claim stored as each line's created_by
# + return - (), or an error
isolated function insertHargaRoleLines(postgresql:Client dbc, int kontrakPayungId,
        models:KontrakPayungHargaRoleInput[] hargaRole, string createdBy) returns error? {
    foreach models:KontrakPayungHargaRoleInput line in hargaRole {
        _ = check dbc->execute(`
            INSERT INTO kontrak_payung_harga_role (kontrak_payung_id, role_id, tipe_harga, nilai,
                    keterangan, created_by)
            VALUES (${kontrakPayungId}, ${line.roleId}, ${line.tipeHarga}, ${line.nilai},
                    ${line?.keterangan}, ${createdBy})`);
    }
    return ();
}

# Soft-deletes a kontrak payung (sets is_deleted = true). Never physically deletes. The caller must
# first ensure it isn't still referenced.
#
# + id - the kontrak payung id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteKontrakPayung(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE kontrak_payung SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}

# Returns up to 100 active kontrak payung (newest first) for the Proyek-form dropdown, optionally
# filtered by owning customer and/or a case-insensitive search over no_kontrak_payung / nama_kontrak.
#
# + customerId - optional exact customer_id filter
# + search - optional case-insensitive filter on no_kontrak_payung or nama_kontrak
# + return - the dropdown options (max 100), or an error
public function getKontrakPayungDropdown(int? customerId, string? search)
        returns models:KontrakPayungDropdownItem[]|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] parts = [
        `SELECT id, no_kontrak_payung AS "noKontrakPayung", nama_kontrak AS "namaKontrak"
         FROM kontrak_payung WHERE is_deleted = false`
    ];
    if customerId is int {
        parts.push(` AND customer_id = ${customerId}`);
    }
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        parts.push(` AND (no_kontrak_payung ILIKE ${pattern} OR nama_kontrak ILIKE ${pattern})`);
    }
    parts.push(` ORDER BY id DESC LIMIT 100`);
    sql:ParameterizedQuery query = sql:queryConcat(...parts);

    return from models:KontrakPayungDropdownItem d in dbc->query(query, models:KontrakPayungDropdownItem)
        select d;
}
