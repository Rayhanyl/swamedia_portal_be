import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Finansial — Saldo Awal Kas + Posisi Kas service =====
#
# Business rules for saldo_awal_kas (opening cash balance, append-only) and a read of the current
# cash position. Domain failures are `models:AppError`; infrastructure failures propagate as plain
# `error`. Date validation reuses `validateRequiredDate` (kontrak_payung_service). There is no
# update/delete — the table is append-only (a correction is a new, later-dated row).

# Lists saldo_awal_kas rows with pagination (newest first).
#
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, or an error
public function getSaldoAwalKas(int page, int 'limit) returns models:SaldoAwalKasListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:SaldoAwalKas[] items; int totalItems;|} result =
        check repositories:findSaldoAwalKas(safeLimit, offset);

    int totalItems = result.totalItems;
    int totalPages = totalItems == 0 ? 0 : (totalItems + safeLimit - 1) / safeLimit;
    models:Pagination pagination = {
        page: safePage,
        'limit: safeLimit,
        totalItems: totalItems,
        totalPages: totalPages
    };
    return {items: result.items, pagination: pagination};
}

# Fetches a single saldo_awal_kas row by id.
#
# + id - the saldo_awal_kas id
# + return - the row, a NOT_FOUND AppError if it does not exist, or an error
public function getSaldoAwalKasById(int id) returns models:SaldoAwalKas|error {
    models:SaldoAwalKas? row = check repositories:findSaldoAwalKasById(id);
    if row is () {
        return utils:notFoundError("Saldo awal kas dengan id " + id.toString() + " tidak ditemukan");
    }
    return row;
}

# Creates a saldo_awal_kas row (append-only).
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created row, a VALIDATION_ERROR AppError, or an error
public function createSaldoAwalKas(models:SaldoAwalKasCreateRequest payload, string subject)
        returns models:SaldoAwalKas|error {
    string tanggal = check validateRequiredDate(payload.tanggal, "Tanggal");
    string? keterangan = normalizeProyekText(payload?.keterangan);
    models:SaldoAwalKas created = check repositories:insertSaldoAwalKas(tanggal, payload.nilai, keterangan, subject);
    logAudit("saldo_awal_kas", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Reads the current cash position (from the `v_posisi_kas` view).
#
# + return - the current cash position, or an error
public function getPosisiKas() returns models:PosisiKas|error {
    return repositories:getPosisiKas();
}
