import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Finansial — Saldo Awal Kas + Posisi Kas repository =====
#
# All access to the append-only `saldo_awal_kas` table (no update/delete — corrections are new,
# later-dated rows) plus a read of the `v_posisi_kas` view for the current cash position.
# Parameterized `sql:ParameterizedQuery` templates only.

# Fetches one page of saldo_awal_kas rows plus the total count, newest first.
#
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total count, or an error
public function findSaldoAwalKas(int 'limit, int offset)
        returns record {|models:SaldoAwalKas[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();
    models:SaldoAwalKas[] items = check from models:SaldoAwalKas s in dbc->query(`
            SELECT id, tanggal::text AS "tanggal", nilai, keterangan,
                   created_at::text AS "createdAt", created_by AS "createdBy"
            FROM saldo_awal_kas
            ORDER BY tanggal DESC, id DESC
            LIMIT ${'limit} OFFSET ${offset}`, models:SaldoAwalKas)
        select s;
    int totalItems = check dbc->queryRow(`SELECT count(*) FROM saldo_awal_kas`);
    return {items: items, totalItems: totalItems};
}

# Fetches a single saldo_awal_kas row by id.
#
# + id - the saldo_awal_kas id
# + return - the row, `()` if not found, or an error
public function findSaldoAwalKasById(int id) returns models:SaldoAwalKas?|error {
    postgresql:Client dbc = check dbClient();
    models:SaldoAwalKas|sql:Error result = dbc->queryRow(`
        SELECT id, tanggal::text AS "tanggal", nilai, keterangan,
               created_at::text AS "createdAt", created_by AS "createdBy"
        FROM saldo_awal_kas WHERE id = ${id}`, models:SaldoAwalKas);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Inserts a new saldo_awal_kas row (append-only) and returns the created row.
#
# + tanggal - the balance date (YYYY-MM-DD)
# + nilai - the opening cash amount
# + keterangan - optional note
# + createdBy - the `sub` claim of the caller
# + return - the created row, or an error
public function insertSaldoAwalKas(string tanggal, decimal nilai, string? keterangan, string createdBy)
        returns models:SaldoAwalKas|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO saldo_awal_kas (tanggal, nilai, keterangan, created_by)
        VALUES (${tanggal}::date, ${nilai}, ${keterangan}, ${createdBy})
        RETURNING id`);
    models:SaldoAwalKas? created = check findSaldoAwalKasById(newId);
    if created is () {
        return error("Saldo awal kas yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Reads the current cash position from the `v_posisi_kas` view. The view always returns exactly one
# row (its scalar subqueries have no driving FROM), with the saldo-derived fields NULL when no
# saldo_awal_kas row exists yet.
#
# + return - the current cash position, or an error
public function getPosisiKas() returns models:PosisiKas|error {
    postgresql:Client dbc = check dbClient();
    return check dbc->queryRow(`
        SELECT tanggal_saldo_awal::text AS "tanggalSaldoAwal", saldo_awal AS "saldoAwal",
               total_inflow AS "totalInflow", total_outflow AS "totalOutflow", posisi_kas AS "posisiKas"
        FROM v_posisi_kas`);
}
