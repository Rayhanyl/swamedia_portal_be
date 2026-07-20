import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Audit Log repository =====
#
# All access to the append-only `audit_log` table. Parameterized `sql:ParameterizedQuery` templates
# only. `insertAuditLog` is called by other services (e.g. `nomor_surat_service` on cancel) to record
# a change to another table — it was originally added in nomor_surat_repository (the first writer)
# and moved here once a dedicated Audit Log module existed. The read functions below back the
# read-only Audit Log report; there is no update/delete — the table is append-only by design.
#
# `perubahan` is stored as plain TEXT holding a JSON-encoded string (NOT a real jsonb column), so
# reads go through an intermediate flat row type and decode it back to `json` with
# fromJsonString() before folding into `models:AuditLogEntry`.

# Writes an audit_log row for a change to another table. `ip_address` is left unset (nullable) since
# there is no request-context plumbing anywhere in this project yet to source it from.
#
# + tableName - the audited table's name (e.g. "nomor_surat")
# + recordId - the audited row's id
# + aksi - "CREATE" / "UPDATE" / "DELETE"
# + perubahan - `{"column": {"old": ..., "new": ...}, ...}`, JSON-encoded into the text column
# + aktor - the `sub` claim of the caller (never from the request body)
# + return - an error if the insert failed
public function insertAuditLog(string tableName, int recordId, string aksi, json perubahan,
        string aktor) returns error? {
    postgresql:Client dbc = check dbClient();
    _ = check dbc->execute(`
        INSERT INTO audit_log (table_name, record_id, aksi, aktor, perubahan)
        VALUES (${tableName}, ${recordId.toString()}, ${aksi}, ${aktor}, ${perubahan.toJsonString()})`);
}

# Flat projection of an audit_log row — the shape the SQL client can bind directly (`perubahan` as
# raw text), before decoding it to `json` and folding into `models:AuditLogEntry`.
#
# + id - primary key
# + tableName - the audited table's name
# + recordId - the audited row's id (stored as text)
# + aksi - CREATE / UPDATE / DELETE
# + aktor - the `sub` claim of whoever made the change
# + ipAddress - optional caller IP
# + perubahan - the JSON-encoded change detail, still as raw text
# + waktu - when the change happened
type AuditLogRow record {|
    int id;
    string tableName;
    string recordId;
    string aksi;
    string aktor;
    string? ipAddress;
    string? perubahan;
    string waktu;
|};

# Fetches one page of audit_log rows matching the optional filters, plus the total count, newest
# first. `tableName`/`aksi`/`recordId` are exact matches (they're identifiers); `aktor` is a
# case-insensitive partial match (useful as a search field); `dateFrom`/`dateTo` filter on
# `waktu::date` (both already-validated YYYY-MM-DD strings from the service layer).
#
# + tableName - optional exact table_name filter
# + aksi - optional exact aksi filter (CREATE / UPDATE / DELETE)
# + aktor - optional case-insensitive partial filter on aktor
# + recordId - optional exact record_id filter
# + dateFrom - optional inclusive start date (YYYY-MM-DD)
# + dateTo - optional inclusive end date (YYYY-MM-DD)
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findAuditLog(string? tableName, string? aksi, string? aktor, string? recordId,
        string? dateFrom, string? dateTo, int 'limit, int offset)
        returns record {|models:AuditLogEntry[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if tableName is string && tableName.trim().length() > 0 {
        conditions.push(` AND table_name = ${tableName}`);
    }
    if aksi is string && aksi.trim().length() > 0 {
        conditions.push(` AND aksi = ${aksi}`);
    }
    if aktor is string && aktor.trim().length() > 0 {
        string pattern = "%" + aktor.trim() + "%";
        conditions.push(` AND aktor ILIKE ${pattern}`);
    }
    if recordId is string && recordId.trim().length() > 0 {
        conditions.push(` AND record_id = ${recordId}`);
    }
    if dateFrom is string {
        conditions.push(` AND waktu::date >= ${dateFrom}::date`);
    }
    if dateTo is string {
        conditions.push(` AND waktu::date <= ${dateTo}::date`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, table_name AS "tableName", record_id AS "recordId", aksi, aktor,
                ip_address AS "ipAddress", perubahan, waktu::text AS waktu
         FROM audit_log WHERE 1 = 1`
    ];
    foreach sql:ParameterizedQuery cond in conditions {
        selectParts.push(cond);
    }
    selectParts.push(` ORDER BY waktu DESC, id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    AuditLogRow[] rows = check from AuditLogRow r in dbc->query(selectQuery, AuditLogRow) select r;
    models:AuditLogEntry[] items = [];
    foreach AuditLogRow r in rows {
        items.push(check toAuditLogEntry(r));
    }

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM audit_log WHERE 1 = 1`];
    foreach sql:ParameterizedQuery cond in conditions {
        countParts.push(cond);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single audit_log row by id.
#
# + id - the audit_log id
# + return - the entry, `()` if not found, or an error
public function findAuditLogById(int id) returns models:AuditLogEntry?|error {
    postgresql:Client dbc = check dbClient();
    AuditLogRow|sql:Error result = dbc->queryRow(`
        SELECT id, table_name AS "tableName", record_id AS "recordId", aksi, aktor,
               ip_address AS "ipAddress", perubahan, waktu::text AS waktu
        FROM audit_log WHERE id = ${id}`, AuditLogRow);
    if result is sql:NoRowsError {
        return ();
    }
    if result is sql:Error {
        return result;
    }
    return toAuditLogEntry(result);
}

# Decodes a flat `AuditLogRow`'s raw-text `perubahan` back to `json` and folds the row into the
# nested `models:AuditLogEntry` shape.
#
# + r - the flat audit_log row
# + return - the assembled entry, or an error if `perubahan` is not valid JSON
function toAuditLogEntry(AuditLogRow r) returns models:AuditLogEntry|error {
    json perubahan = ();
    string? rawPerubahan = r.perubahan;
    if rawPerubahan is string {
        perubahan = check rawPerubahan.fromJsonString();
    }
    return {
        id: r.id,
        tableName: r.tableName,
        recordId: r.recordId,
        aksi: r.aksi,
        aktor: r.aktor,
        ipAddress: r.ipAddress,
        perubahan: perubahan,
        waktu: r.waktu
    };
}
