import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Master Data — Customer repository =====
#
# All access to the `customer` table. Parameterized `sql:ParameterizedQuery` templates only.
# The detail read uses LEFT JOINs to karyawan/industri to resolve display names in a single
# query (no N+1). Create/update return the new id and let the service re-read the joined detail.

# Fetches one page of non-deleted customers (list projection, raw FK ids) matching the optional
# filters, plus the total count. `search` matches nama (ILIKE).
#
# + search - optional case-insensitive filter on nama
# + amId - optional exact am_id filter
# + industriId - optional exact industri_id filter
# + statusPeluang - optional exact status_peluang filter
# + jenisCustomer - optional exact jenis_customer filter
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findCustomers(string? search, int? amId, int? industriId, string? statusPeluang,
        string? jenisCustomer, int 'limit, int offset)
        returns record {|models:Customer[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND nama ILIKE ${pattern}`);
    }
    if amId is int {
        conditions.push(` AND am_id = ${amId}`);
    }
    if industriId is int {
        conditions.push(` AND industri_id = ${industriId}`);
    }
    if statusPeluang is string && statusPeluang.trim().length() > 0 {
        conditions.push(` AND status_peluang = ${statusPeluang}`);
    }
    if jenisCustomer is string && jenisCustomer.trim().length() > 0 {
        conditions.push(` AND jenis_customer = ${jenisCustomer}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, nama, am_id AS "amId", industri_id AS "industriId",
                status_peluang AS "statusPeluang", jenis_customer AS "jenisCustomer"
         FROM customer WHERE is_deleted = false`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Customer[] items = check from models:Customer c in dbc->query(selectQuery, models:Customer)
        select c;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM customer WHERE is_deleted = false`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted customer (detail projection) by id, LEFT JOINing karyawan and
# industri so the Account Manager name and industri name come back in one round-trip.
#
# + id - the customer id
# + return - the customer detail, `()` if not found (or already deleted), or an error
public function findCustomerById(int id) returns models:CustomerDetail?|error {
    postgresql:Client dbc = check dbClient();
    models:CustomerDetail|sql:Error result = dbc->queryRow(`
        SELECT c.id, c.nama, c.am_id AS "amId", k.nama AS "amNama",
               c.industri_id AS "industriId", i.nama AS "industriNama",
               c.status_peluang AS "statusPeluang", c.jenis_customer AS "jenisCustomer",
               c.created_at::text AS "createdAt", c.updated_at::text AS "updatedAt",
               c.created_by AS "createdBy", c.updated_by AS "updatedBy"
        FROM customer c
        LEFT JOIN karyawan k ON k.id = c.am_id AND k.is_deleted = false
        LEFT JOIN industri i ON i.id = c.industri_id AND i.is_deleted = false
        WHERE c.id = ${id} AND c.is_deleted = false`, models:CustomerDetail);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether a non-deleted customer with the given id exists (used to validate FK refs
# from other masters, e.g. contact.customer_id).
#
# + id - the customer id to check
# + return - true if an active customer with that id exists, or an error
public function customerExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM customer WHERE id = ${id} AND is_deleted = false`);
    return count > 0;
}

# Returns whether this customer still has any active dependent row in proyek, contact,
# kontrak_payung or kontrak_biasa (blocks soft-delete). One query, readable OR-EXISTS chain.
#
# + id - the customer id
# + return - true if any active dependency exists, or an error
public function isCustomerReferenced(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean referenced = check dbc->queryRow(`
        SELECT EXISTS(SELECT 1 FROM proyek WHERE customer_id = ${id} AND is_deleted = false)
            OR EXISTS(SELECT 1 FROM contact WHERE customer_id = ${id} AND is_deleted = false)
            OR EXISTS(SELECT 1 FROM kontrak_payung WHERE customer_id = ${id} AND is_deleted = false)
            OR EXISTS(SELECT 1 FROM kontrak_biasa WHERE customer_id = ${id} AND is_deleted = false)`);
    return referenced;
}

# Inserts a new customer and returns its generated id (the service re-reads the joined detail).
#
# + nama - customer name
# + amId - Account Manager karyawan id, or ()
# + industriId - industri id, or ()
# + statusPeluang - opportunity status
# + jenisCustomer - customer type, or ()
# + createdBy - the `sub` claim of the caller
# + return - the new customer id, or an error
public function insertCustomer(string nama, int? amId, int? industriId, string statusPeluang,
        string? jenisCustomer, string createdBy) returns int|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO customer (nama, am_id, industri_id, status_peluang, jenis_customer, created_by)
        VALUES (${nama}, ${amId}, ${industriId}, ${statusPeluang}, ${jenisCustomer}, ${createdBy})
        RETURNING id`);
    return newId;
}

# Updates a non-deleted customer and returns its id (the service re-reads the joined detail).
#
# + id - the customer id
# + nama - new name
# + amId - new Account Manager id, or ()
# + industriId - new industri id, or ()
# + statusPeluang - new opportunity status
# + jenisCustomer - new customer type, or ()
# + updatedBy - the `sub` claim of the caller
# + return - the customer id, `()` if the row does not exist (or is deleted), or an error
public function updateCustomer(int id, string nama, int? amId, int? industriId, string statusPeluang,
        string? jenisCustomer, string updatedBy) returns int?|error {
    postgresql:Client dbc = check dbClient();
    int|sql:Error updated = dbc->queryRow(`
        UPDATE customer SET nama = ${nama}, am_id = ${amId}, industri_id = ${industriId},
               status_peluang = ${statusPeluang}, jenis_customer = ${jenisCustomer},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id`, int);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Soft-deletes a customer (sets is_deleted = true). Never physically deletes.
#
# + id - the customer id
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already deleted), or an error
public function softDeleteCustomer(int id, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE customer SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
