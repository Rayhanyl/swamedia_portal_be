import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Contact repository =====
#
# All access to the `contact` table. Parameterized `sql:ParameterizedQuery` templates only.
# `jabatan` and `tipe_kontak` come from the v1.7 addendum migration.

# Fetches one page of non-deleted contacts matching the optional filters, plus the total count.
# `search` matches nama, email or jabatan (ILIKE); `customerId`/`tipeKontak` filter by exact value.
#
# + customerId - optional exact customer_id filter (the most common query)
# + search - optional case-insensitive filter on nama/email/jabatan
# + tipeKontak - optional exact tipe_kontak filter (UTAMA / AKTIF / PROSPEK)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findContacts(int? customerId, string? search, string? tipeKontak, int 'limit, int offset)
        returns record {|models:Contact[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if customerId is int {
        conditions.push(` AND customer_id = ${customerId}`);
    }
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (nama ILIKE ${pattern} OR email ILIKE ${pattern} OR jabatan ILIKE ${pattern})`);
    }
    if tipeKontak is string && tipeKontak.trim().length() > 0 {
        conditions.push(` AND tipe_kontak = ${tipeKontak}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, customer_id AS "customerId", nama, jabatan, email, telepon, tipe_kontak AS "tipeKontak"
         FROM contact WHERE is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Contact[] items = check from models:Contact ct in dbc->query(selectQuery, models:Contact)
        select ct;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM contact WHERE is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted contact (with audit columns) by id.
#
# + id - the contact id
# + return - the contact, `()` if not found (or already deleted), or an error
public function findContactById(int id) returns models:Contact?|error {
    postgresql:Client dbc = check dbClient();
    models:Contact|sql:Error result = dbc->queryRow(`
        SELECT id, customer_id AS "customerId", nama, jabatan, email, telepon, tipe_kontak AS "tipeKontak",
               created_at::text AS "createdAt", updated_at::text AS "updatedAt",
               created_by AS "createdBy", updated_by AS "updatedBy"
        FROM contact WHERE id = ${id} AND is_deleted = false`, models:Contact);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted contact of the same customer already uses the given email.
# Only meaningful when email is non-null (Postgres UNIQUE treats NULLs as distinct, so the
# friendly (customer_id, email) uniqueness check is done here — see the Tags module).
#
# + customerId - the owning customer id
# + email - the (non-null) email to check
# + excludeId - a contact id to exclude (0 = none)
# + return - true if a conflicting (customer_id, email) exists, or an error
public function contactEmailExists(int customerId, string email, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM contact
        WHERE customer_id = ${customerId} AND email = ${email} AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Inserts a new contact and returns the created row (via RETURNING).
#
# + customerId - owning customer id
# + nama - contact name
# + jabatan - position/title, or ()
# + email - email, or ()
# + telepon - phone, or ()
# + tipeKontak - contact role (UTAMA / AKTIF / PROSPEK)
# + createdBy - the `sub` claim of the caller
# + return - the created contact, or an error
public function insertContact(int customerId, string nama, string? jabatan, string? email,
        string? telepon, string tipeKontak, string createdBy) returns models:Contact|error {
    postgresql:Client dbc = check dbClient();
    models:Contact created = check dbc->queryRow(`
        INSERT INTO contact (customer_id, nama, jabatan, email, telepon, tipe_kontak, created_by)
        VALUES (${customerId}, ${nama}, ${jabatan}, ${email}, ${telepon}, ${tipeKontak}, ${createdBy})
        RETURNING id, customer_id AS "customerId", nama, jabatan, email, telepon, tipe_kontak AS "tipeKontak",
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`);
    return created;
}

# Updates a non-deleted contact and returns the updated row (via RETURNING).
#
# + id - the contact id
# + customerId - new owning customer id
# + nama - new name
# + jabatan - new position, or ()
# + email - new email, or ()
# + telepon - new phone, or ()
# + tipeKontak - new contact role
# + updatedBy - the `sub` claim of the caller
# + return - the updated contact, `()` if the row does not exist (or is deleted), or an error
public function updateContact(int id, int customerId, string nama, string? jabatan, string? email,
        string? telepon, string tipeKontak, string updatedBy) returns models:Contact?|error {
    postgresql:Client dbc = check dbClient();
    models:Contact|sql:Error updated = dbc->queryRow(`
        UPDATE contact SET customer_id = ${customerId}, nama = ${nama}, jabatan = ${jabatan},
               email = ${email}, telepon = ${telepon}, tipe_kontak = ${tipeKontak},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id, customer_id AS "customerId", nama, jabatan, email, telepon, tipe_kontak AS "tipeKontak",
                  created_at::text AS "createdAt", updated_at::text AS "updatedAt",
                  created_by AS "createdBy", updated_by AS "updatedBy"`, models:Contact);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Soft-deletes a contact (sets is_deleted = true). Never physically deletes.
#
# + id - the contact id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteContact(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE contact SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
