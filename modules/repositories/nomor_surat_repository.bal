import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== e-Office — Daftar Surat (nomor_surat) repository =====
#
# All access to the `nomor_surat` table. Parameterized `sql:ParameterizedQuery` templates only
# (never string concatenation). List/detail reads JOIN kategori_surat and LEFT JOIN proyek to
# resolve display names in a single query (no N+1). The kategori_surat JOIN is a plain INNER JOIN
# with no is_deleted filter to worry about — `kategori_surat` has no soft delete (it's hard-deleted,
# and only when zero nomor_surat rows reference it — see kategori_surat_repository.bal), so the
# category a letter points at is guaranteed to still exist. The proyek LEFT JOIN, by contrast, IS
# filtered by is_deleted so a soft-deleted project surfaces null display names (matching the
# customer repository's convention).
#
# SCHEMA v2 NOTE: `nomor_surat` has no `nomor`/`urutan` columns — only a single `no_surat`
# (UNIQUE) column, plus a dedicated `is_dibatalkan` flag distinct from the standard `is_deleted`
# soft-delete column (mirrors how `kategori_surat.status` is separate from its `is_deleted`).
# The API still exposes `nomor`/`urutan`/`isDibatalkan` field names (unchanged contract) — they
# are derived here: `nomor` is `no_surat` as-is, `urutan` is the trailing zero-padded number
# parsed back out of `no_surat` (format `{prefix}-{kodeKategori}-{tahun}-{urutan}`, e.g.
# "SK-DR-02-2026-012"), and `isDibatalkan` reads `is_dibatalkan`, NOT `is_deleted`.
#
# ON `transaction { ... }` ALONE NOT BEING ENOUGH (see `insertNomorSurat`): wrapping the
# read-MAX-then-insert sequence in a Ballerina `transaction` block guarantees the SELECT and the
# INSERT run on the same underlying Postgres transaction, but it does NOT by itself take any lock.
# Postgres's default isolation level, READ COMMITTED, lets the MAX-urutan read run as a plain MVCC
# snapshot read that acquires no row lock at all. So two concurrent transactions can both read
# urutan = 12, both compute urutan = 13, and both attempt to INSERT it — the `uq_nomor_surat_no`
# unique constraint would still catch that specific case at INSERT time (one insert blocks/aborts
# against the other), but relying on that alone means every legitimate concurrent pair of creates
# has a real chance of one request being needlessly bounced with a constraint-violation-turned-409,
# purely due to a read/insert race the application could have avoided. `insertNomorSurat` closes
# the gap explicitly with `pg_advisory_xact_lock`, serializing per (kategori_surat_id, tahun)
# BEFORE the MAX read, so the second transaction simply waits for the first to commit and then
# reads the up-to-date MAX — no wasted rollback for legitimate concurrent traffic, and the unique
# constraint remains only as a last-resort safety net.
#
# NOTE: the `(regexp_match(no_surat, '-([0-9]+)$'))[1]::int` expression that parses `urutan` back
# out of `no_surat` is inlined at every call site rather than shared via a Ballerina string
# constant — `sql:ParameterizedQuery` backtick templates only allow `${}` as a BOUND PARAMETER
# placeholder, never as raw SQL text splicing, so a shared fragment can't be interpolated in.

# Fetches one page of nomor_surat rows matching the optional filters, plus the total count.
# `search` matches nomor / tujuan / perihal (ILIKE). `tahun` is always applied (the service
# defaults it to the current year when the caller omits it). By default only active (non-cancelled)
# letters are included; `includeDibatalkan` additionally surfaces cancelled ones (with
# `alasanPembatalan` filled and `isDibatalkan = true`) for audit/report views.
#
# + search - optional case-insensitive filter on nomor/tujuan/perihal
# + tahun - exact filter on the numbering year
# + kategoriSuratId - optional exact kategori_surat_id filter
# + proyekId - optional exact proyek_id filter
# + includeDibatalkan - when true, also includes cancelled (is_dibatalkan = true) letters
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findNomorSurat(string? search, int tahun, int? kategoriSuratId, int? proyekId,
        boolean includeDibatalkan, int 'limit, int offset)
        returns record {|models:NomorSurat[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    // is_deleted is the standard soft-delete flag and is ALWAYS excluded, regardless of
    // includeDibatalkan — cancellation is tracked separately via is_dibatalkan.
    sql:ParameterizedQuery[] conditions = [` AND ns.tahun = ${tahun}`, ` AND ns.is_deleted = false`];
    if !includeDibatalkan {
        conditions.push(` AND ns.is_dibatalkan = false`);
    }
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (ns.no_surat ILIKE ${pattern} OR ns.tujuan ILIKE ${pattern} OR ns.perihal ILIKE ${pattern})`);
    }
    if kategoriSuratId is int {
        conditions.push(` AND ns.kategori_surat_id = ${kategoriSuratId}`);
    }
    if proyekId is int {
        conditions.push(` AND ns.proyek_id = ${proyekId}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT ns.id, ns.kategori_surat_id AS "kategoriSuratId",
                ks.kode AS "kategoriKode", ks.nama AS "kategoriNama",
                ns.proyek_id AS "proyekId", p.kode_proyek AS "kodeProyek", p.nama_proyek AS "namaProyek",
                ns.tanggal::text AS "tanggal", ns.tahun,
                (regexp_match(ns.no_surat, '-([0-9]+)$'))[1]::int AS "urutan", ns.no_surat AS "nomor",
                ns.tujuan, ns.perihal, ns.keterangan,
                ns.alasan_pembatalan AS "alasanPembatalan", ns.is_dibatalkan AS "isDibatalkan"
         FROM nomor_surat ns
         JOIN kategori_surat ks ON ks.id = ns.kategori_surat_id
         LEFT JOIN proyek p ON p.id = ns.proyek_id AND p.is_deleted = false
         WHERE true`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY ns.id DESC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:NomorSurat[] items = check from models:NomorSurat n in dbc->query(selectQuery, models:NomorSurat)
        select n;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM nomor_surat ns WHERE true`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single non-deleted nomor_surat (with joined display names + audit columns) by id.
#
# + id - the nomor_surat id
# + return - the surat, `()` if not found (or already deleted), or an error
public function findNomorSuratById(int id) returns models:NomorSurat?|error {
    postgresql:Client dbc = check dbClient();
    models:NomorSurat|sql:Error result = dbc->queryRow(`
        SELECT ns.id, ns.kategori_surat_id AS "kategoriSuratId",
               ks.kode AS "kategoriKode", ks.nama AS "kategoriNama",
               ns.proyek_id AS "proyekId", p.kode_proyek AS "kodeProyek", p.nama_proyek AS "namaProyek",
               ns.tanggal::text AS "tanggal", ns.tahun,
               (regexp_match(ns.no_surat, '-([0-9]+)$'))[1]::int AS "urutan", ns.no_surat AS "nomor",
               ns.tujuan, ns.perihal, ns.keterangan,
               ns.alasan_pembatalan AS "alasanPembatalan", ns.is_dibatalkan AS "isDibatalkan",
               ns.created_at::text AS "createdAt", ns.updated_at::text AS "updatedAt",
               ns.created_by AS "createdBy", ns.updated_by AS "updatedBy"
        FROM nomor_surat ns
        JOIN kategori_surat ks ON ks.id = ns.kategori_surat_id
        LEFT JOIN proyek p ON p.id = ns.proyek_id AND p.is_deleted = false
        WHERE ns.id = ${id} AND ns.is_deleted = false`, models:NomorSurat);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Reads the letter-number prefix from sys_config (key = 'prefix_nomor_surat').
#
# + return - the configured prefix, or `()` when the row is missing or its value is NULL, or an error
public function getPrefixNomorSurat() returns string?|error {
    postgresql:Client dbc = check dbClient();
    record {|string? value;|}|sql:Error row =
        dbc->queryRow(`SELECT value FROM sys_config WHERE key = 'prefix_nomor_surat'`);
    if row is sql:NoRowsError {
        return ();
    }
    if row is sql:Error {
        return row;
    }
    return row.value;
}

# Generates the next letter number and inserts the row ATOMICALLY, with an explicit Postgres
# advisory lock closing the read-MAX/insert race window (see the module-level note below for why
# `transaction { ... }` alone is NOT sufficient under READ COMMITTED). Reading MAX(urutan)+1 and
# the INSERT happen inside one database transaction, serialized per (kategori_surat_id, tahun) by
# `pg_advisory_xact_lock`. Since schema v2 has no `urutan` column, the current MAX is parsed back
# out of every existing `no_surat` value for the pair (see the module-level note on
# `regexp_match`) — across ALL rows regardless of `is_dibatalkan`/`is_deleted`, so a historic
# number is never reused. If the lock cannot be acquired within the configured timeout (a peer
# transaction stuck/deadlocked), or — as a last-resort safety net — the unique constraint still
# fires, the transaction rolls back and the caller gets back a plain `error` that the service maps
# to CONFLICT 409.
#
# + kategoriSuratId - the (already validated) kategori_surat id
# + prefix - the prefix read from sys_config
# + kodeKategori - the kategori_surat.kode (e.g. "DR-02")
# + proyekId - optional proyek id, or ()
# + tanggal - the letter date (YYYY-MM-DD)
# + tahun - the numbering year (EXTRACT(YEAR FROM tanggal))
# + tujuan - the recipient
# + perihal - the subject
# + keterangan - optional notes, or ()
# + createdBy - the `sub` claim of the caller
# + return - the new nomor_surat id, or an error (lock timeout or unique-constraint violation on race)
public function insertNomorSurat(int kategoriSuratId, string prefix, string kodeKategori, int? proyekId,
        string tanggal, int tahun, string tujuan, string perihal, string? keterangan, string createdBy)
        returns int|error {
    postgresql:Client dbc = check dbClient();
    string lockKey = kategoriSuratId.toString() + "-" + tahun.toString();
    int newId = 0;
    transaction {
        // Cap how long this request waits for the advisory lock, so a peer transaction that is
        // stuck or deadlocked cannot hang this request forever. `LOCAL` scopes the setting to this
        // transaction only — Postgres discards it automatically at COMMIT or ROLLBACK, no manual
        // reset needed.
        _ = check dbc->execute(`SET LOCAL lock_timeout = '5s'`);

        // Serialize per (kategori_surat_id, tahun) BEFORE reading MAX(urutan). An advisory lock is
        // used instead of `SELECT ... FOR UPDATE` on existing nomor_surat rows because the very
        // first letter for a given (kategori, tahun) pair has no existing row to lock — the lock
        // key must exist independently of whether any row does yet. `pg_advisory_xact_lock` is
        // transaction-scoped (the `_xact_` variant), so Postgres releases it automatically on
        // COMMIT or ROLLBACK; there is no manual unlock call, and therefore no path where the lock
        // is left held after an error. If the lock is not granted within the `lock_timeout` above,
        // this call itself fails with a lock-timeout error (SQLSTATE 55P03), which the service
        // maps to CONFLICT via `isLockTimeout`.
        _ = check dbc->queryRow(
            `SELECT pg_advisory_xact_lock(hashtext(${lockKey})) IS NULL AS locked`, boolean);

        int nextUrutan = check dbc->queryRow(`
            SELECT COALESCE(MAX((regexp_match(no_surat, '-([0-9]+)$'))[1]::int), 0) + 1
            FROM nomor_surat
            WHERE kategori_surat_id = ${kategoriSuratId} AND tahun = ${tahun}`);
        string nomor = formatNomor(prefix, kodeKategori, tahun, nextUrutan);
        newId = check dbc->queryRow(`
            INSERT INTO nomor_surat (kategori_surat_id, proyek_id, tanggal, tahun, no_surat,
                    tujuan, perihal, keterangan, created_by)
            VALUES (${kategoriSuratId}, ${proyekId}, ${tanggal}::date, ${tahun}, ${nomor},
                    ${tujuan}, ${perihal}, ${keterangan}, ${createdBy})
            RETURNING id`);
        check commit;
    }
    return newId;
}

# Updates the mutable fields of a non-deleted nomor_surat and returns its id. Deliberately does
# NOT touch kategori_surat_id, tahun, urutan or nomor — those are immutable after create.
#
# + id - the nomor_surat id
# + tanggal - new letter date (YYYY-MM-DD)
# + proyekId - new proyek id, or ()
# + tujuan - new recipient
# + perihal - new subject
# + keterangan - new notes, or ()
# + updatedBy - the `sub` claim of the caller
# + return - the id, `()` if the row does not exist (or is deleted), or an error
public function updateNomorSurat(int id, string tanggal, int? proyekId, string tujuan, string perihal,
        string? keterangan, string updatedBy) returns int?|error {
    postgresql:Client dbc = check dbClient();
    int|sql:Error updated = dbc->queryRow(`
        UPDATE nomor_surat SET tanggal = ${tanggal}::date, proyek_id = ${proyekId}, tujuan = ${tujuan},
               perihal = ${perihal}, keterangan = ${keterangan}, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_deleted = false
        RETURNING id`, int);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Cancels a nomor_surat: sets is_dibatalkan = true AND alasan_pembatalan in the SAME UPDATE
# statement (never a physical delete, never `is_deleted`, and never two separate queries) — a
# cancelled letter is NOT soft-deleted, it just carries the `is_dibatalkan` flag (schema v2 keeps
# the two concepts separate, same as `kategori_surat.status` vs `is_deleted`). Only affects a row
# that is not already cancelled — cancelling an already-cancelled (or non-existent) letter affects
# zero rows, which the service reports as NOT_FOUND rather than silently succeeding again.
#
# + id - the nomor_surat id
# + alasanPembatalan - the mandatory cancellation reason (already validated by the service)
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (or was already cancelled), or an error
public function cancelNomorSurat(int id, string alasanPembatalan, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE nomor_surat SET is_dibatalkan = true, alasan_pembatalan = ${alasanPembatalan},
               updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND is_dibatalkan = false AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}

# Read-only next urutan for the (kategori, tahun) pair — MAX(urutan)+1 parsed back out of every
# existing `no_surat` value for the pair (across ALL rows, including cancelled/soft-deleted ones).
# Used by the PREVIEW path only: it takes no lock and reserves nothing. The transactional insert
# path reads the same value under its own transaction instead of calling this, so the read and the
# insert stay atomic.
#
# + kategoriSuratId - the kategori_surat id
# + tahun - the numbering year
# + return - the next urutan (1 when no rows exist yet), or an error
public function getNextUrutan(int kategoriSuratId, int tahun) returns int|error {
    postgresql:Client dbc = check dbClient();
    int next = check dbc->queryRow(`
        SELECT COALESCE(MAX((regexp_match(no_surat, '-([0-9]+)$'))[1]::int), 0) + 1
        FROM nomor_surat
        WHERE kategori_surat_id = ${kategoriSuratId} AND tahun = ${tahun}`);
    return next;
}

# Builds the canonical letter-number string from its parts. Single source of truth for the number
# format, shared by the transactional insert (`insertNomorSurat`) and the read-only preview
# (`getNextUrutan` + this) so the two paths can never drift apart.
#
# + prefix - the sys_config prefix (e.g. "SK")
# + kodeKategori - the kategori_surat.kode (e.g. "DR-02")
# + tahun - the numbering year
# + urutan - the sequence number within (kategori, tahun)
# + return - e.g. "SK-DR-02-2026-012"
public isolated function formatNomor(string prefix, string kodeKategori, int tahun, int urutan) returns string {
    return string `${prefix}-${kodeKategori}-${tahun}-${padUrutan(urutan)}`;
}

# Left-pads an urutan to at least 3 digits (12 -> "012", 7 -> "007", 1234 -> "1234").
#
# + urutan - the sequence number to pad
# + return - the zero-padded string
isolated function padUrutan(int urutan) returns string {
    string s = urutan.toString();
    if s.length() >= 3 {
        return s;
    }
    if s.length() == 2 {
        return "0" + s;
    }
    return "00" + s;
}
