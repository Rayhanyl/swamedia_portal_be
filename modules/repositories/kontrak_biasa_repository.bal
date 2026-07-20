import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Kontrak Biasa repository =====
#
# All access to the `kontrak_biasa` table. Parameterized `sql:ParameterizedQuery` templates only.
# List/detail JOIN `customer` (customerNama) and LEFT JOIN `kontrak_payung` (parent noKontrakPayung)
# to resolve display names in a single query (no N+1). Unlike kontrak_payung this has no child
# table and `no_kontrak_biasa` is user-supplied (not generated), so inserts are a plain single
# statement — no advisory-lock numbering.

# Fetches one page of non-deleted kontrak biasa matching the optional filters, plus the total count.
# `search` matches no_kontrak_biasa OR nama_kontrak (ILIKE).
#
# + search - optional case-insensitive filter on no_kontrak_biasa or nama_kontrak
# + customerId - optional exact customer_id filter
# + kontrakPayungId - optional exact kontrak_payung_id filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findKontrakBiasa(string? search, int? customerId, int? kontrakPayungId, int 'limit, int offset)
        returns record {|models:KontrakBiasa[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kb.no_kontrak_biasa ILIKE ${pattern} OR kb.nama_kontrak ILIKE ${pattern})`);
    }
    if customerId is int {
        conditions.push(` AND kb.customer_id = ${customerId}`);
    }
    if kontrakPayungId is int {
        conditions.push(` AND kb.kontrak_payung_id = ${kontrakPayungId}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT kb.id, kb.kontrak_payung_id AS "kontrakPayungId", kp.no_kontrak_payung AS "noKontrakPayung",
                kb.customer_id AS "customerId", c.nama AS "customerNama",
                kb.no_kontrak_biasa AS "noKontrakBiasa", kb.nama_kontrak AS "namaKontrak",
                kb.tanggal_kontrak::text AS "tanggalKontrak", kb.nilai
         FROM kontrak_biasa kb
         JOIN customer c ON c.id = kb.customer_id
         LEFT JOIN kontrak_payung kp ON kp.id = kb.kontrak_payung_id
         WHERE kb.is_deleted = false`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY kb.id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:KontrakBiasa[] items = check from models:KontrakBiasa k in dbc->query(selectQuery, models:KontrakBiasa)
        select k;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM kontrak_biasa kb WHERE kb.is_deleted = false`];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted kontrak biasa (with joined names + audit columns) by id.
#
# + id - the kontrak biasa id
# + return - the contract, `()` if not found (or deleted), or an error
public function findKontrakBiasaById(int id) returns models:KontrakBiasa?|error {
    postgresql:Client dbc = check dbClient();
    models:KontrakBiasa|sql:Error result = dbc->queryRow(`
        SELECT kb.id, kb.kontrak_payung_id AS "kontrakPayungId", kp.no_kontrak_payung AS "noKontrakPayung",
               kb.customer_id AS "customerId", c.nama AS "customerNama",
               kb.no_kontrak_biasa AS "noKontrakBiasa", kb.nama_kontrak AS "namaKontrak",
               kb.tanggal_kontrak::text AS "tanggalKontrak", kb.nilai,
               kb.created_at::text AS "createdAt", kb.updated_at::text AS "updatedAt",
               kb.created_by AS "createdBy", kb.updated_by AS "updatedBy"
        FROM kontrak_biasa kb
        JOIN customer c ON c.id = kb.customer_id
        LEFT JOIN kontrak_payung kp ON kp.id = kb.kontrak_payung_id
        WHERE kb.id = ${id} AND kb.is_deleted = false`, models:KontrakBiasa);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted kontrak biasa already uses the given no_kontrak_biasa
# (mirrors `uq_kontrak_biasa_no` as a friendly pre-check). `excludeId` skips a row (0 on insert;
# target id on update).
#
# + noKontrakBiasa - the contract number to check
# + excludeId - a kontrak biasa id to exclude (0 = none)
# + return - true if a conflicting number exists, or an error
public function kontrakBiasaNoExists(string noKontrakBiasa, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM kontrak_biasa
        WHERE no_kontrak_biasa = ${noKontrakBiasa} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether any non-deleted proyek still references this kontrak biasa — used to block
# deletion of a contract that is still in use.
#
# + id - the kontrak biasa id
# + return - true if referenced, or an error
public function isKontrakBiasaReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM proyek WHERE kontrak_biasa_id = ${id} AND is_deleted = false)`);
    return referenced;
}

# Returns the owning customer_id of a non-deleted kontrak_biasa row — used to validate that a
# proyek's optional kontrak_biasa_id actually belongs to the same customer as the proyek. Moved
# here from proyek_repository now that the Kontrak Biasa module exists (proyek_service still calls
# this by name — functions are module-scoped, not file-scoped, so nothing else needed to change).
#
# + id - the kontrak_biasa id
# + return - its customer_id, `()` if not found (or deleted), or an error
public function kontrakBiasaCustomerId(int id) returns int?|error {
    postgresql:Client dbc = check dbClient();
    record {|int customerId;|}|sql:Error row = dbc->queryRow(
        `SELECT customer_id AS "customerId" FROM kontrak_biasa WHERE id = ${id} AND is_deleted = false`);
    if row is sql:NoRowsError {
        return ();
    }
    if row is sql:Error {
        return row;
    }
    return row.customerId;
}

# Inserts a new kontrak biasa and returns the created row (assembled with joined names + audit).
#
# + kontrakPayungId - optional parent kontrak payung id
# + customerId - the owning customer
# + noKontrakBiasa - the unique contract number
# + namaKontrak - the contract name
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + nilai - optional contract value
# + createdBy - the `sub` claim of the caller
# + return - the created contract, or an error
public function insertKontrakBiasa(int? kontrakPayungId, int customerId, string noKontrakBiasa,
        string namaKontrak, string tanggalKontrak, decimal? nilai, string createdBy)
        returns models:KontrakBiasa|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO kontrak_biasa (kontrak_payung_id, customer_id, no_kontrak_biasa, nama_kontrak,
                tanggal_kontrak, nilai, created_by)
        VALUES (${kontrakPayungId}, ${customerId}, ${noKontrakBiasa}, ${namaKontrak},
                ${tanggalKontrak}::date, ${nilai}, ${createdBy})
        RETURNING id`);
    models:KontrakBiasa? created = check findKontrakBiasaById(newId);
    if created is () {
        return error("Kontrak biasa yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted kontrak biasa and returns the updated row. `kontrak_payung_id`/`nilai` are
# written as given (passing () clears them — full-replace semantics matching Proyek).
#
# + id - the kontrak biasa id
# + kontrakPayungId - new parent kontrak payung id, or () to clear it
# + customerId - new owning customer
# + noKontrakBiasa - new contract number
# + namaKontrak - new contract name
# + tanggalKontrak - new contract date (YYYY-MM-DD)
# + nilai - new contract value, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - the updated contract, `()` if it does not exist (or is deleted), or an error
public function updateKontrakBiasa(int id, int? kontrakPayungId, int customerId, string noKontrakBiasa,
        string namaKontrak, string tanggalKontrak, decimal? nilai, string updatedBy)
        returns models:KontrakBiasa?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE kontrak_biasa SET kontrak_payung_id = ${kontrakPayungId}, customer_id = ${customerId},
               no_kontrak_biasa = ${noKontrakBiasa}, nama_kontrak = ${namaKontrak},
               tanggal_kontrak = ${tanggalKontrak}::date, nilai = ${nilai},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findKontrakBiasaById(id);
}

# Soft-deletes a kontrak biasa (sets is_deleted = true). Never physically deletes. The caller must
# first ensure it isn't still referenced.
#
# + id - the kontrak biasa id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteKontrakBiasa(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE kontrak_biasa SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}

# Returns up to 100 active kontrak biasa (newest first) for the Proyek-form dropdown, optionally
# filtered by owning customer and/or a case-insensitive search over no_kontrak_biasa / nama_kontrak.
#
# + customerId - optional exact customer_id filter
# + search - optional case-insensitive filter on no_kontrak_biasa or nama_kontrak
# + return - the dropdown options (max 100), or an error
public function getKontrakBiasaDropdown(int? customerId, string? search)
        returns models:KontrakBiasaDropdownItem[]|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] parts = [
        `SELECT id, no_kontrak_biasa AS "noKontrakBiasa", nama_kontrak AS "namaKontrak"
         FROM kontrak_biasa WHERE is_deleted = false`
    ];
    if customerId is int {
        parts.push(` AND customer_id = ${customerId}`);
    }
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        parts.push(` AND (no_kontrak_biasa ILIKE ${pattern} OR nama_kontrak ILIKE ${pattern})`);
    }
    parts.push(` ORDER BY id DESC LIMIT 100`);
    sql:ParameterizedQuery query = sql:queryConcat(...parts);

    return from models:KontrakBiasaDropdownItem d in dbc->query(query, models:KontrakBiasaDropdownItem)
        select d;
}
