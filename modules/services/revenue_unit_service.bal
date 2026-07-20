import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Revenue Unit reports service =====
#
# Read-only reporting on top of `target_revenue_unit` (targets) and the `v_realisasi_revenue_tw` view
# (cash-basis actuals). Domain failures are `models:AppError`; infrastructure failures propagate as
# plain `error`. `tahun` defaults to the current year (reusing `currentProyekYear` from proyek_service)
# and is range-checked with `validateProyekTahun`; an optional `unitId` filter is validated to exist.

# Full Revenue Unit report (target vs realisasi per unit) for a year.
#
# + tahun - the report year, or () for the current year
# + unitId - optional single-unit filter
# + return - the report rows, a VALIDATION_ERROR AppError, or an error
public function getRevenueUnitReport(int? tahun, int? unitId) returns models:RevenueUnitRow[]|error {
    int year = check resolveTahun(tahun);
    check ensureUnitFilter(unitId);
    return repositories:findRevenueUnitReport(year, unitId);
}

# Per-triwulan Revenue Unit report for a year.
#
# + tahun - the report year, or () for the current year
# + triwulan - the quarter (1..4)
# + unitId - optional single-unit filter
# + return - the per-quarter report rows, a VALIDATION_ERROR AppError, or an error
public function getRevenueUnitTw(int? tahun, int triwulan, int? unitId) returns models:RevenueUnitTwRow[]|error {
    int year = check resolveTahun(tahun);
    check validateTriwulan(triwulan);
    check ensureUnitFilter(unitId);
    return repositories:findRevenueUnitTw(year, triwulan, unitId);
}

# Revenue Unit chart (four quarter points of target vs realisasi) for a year, optionally scoped to a
# single unit.
#
# + tahun - the chart year, or () for the current year
# + unitId - optional single-unit filter (() = aggregate across all units)
# + return - the assembled chart, a VALIDATION_ERROR AppError, or an error
public function getRevenueUnitChart(int? tahun, int? unitId) returns models:RevenueUnitChart|error {
    int year = check resolveTahun(tahun);

    string? unitNama = ();
    if unitId is int {
        models:Unit? unit = check repositories:findUnitById(unitId);
        if unit is () {
            return utils:validationError("Unit tidak ditemukan");
        }
        unitNama = unit.namaUnit;
    }

    models:RevenueUnitChartPoint[] points = check repositories:findRevenueUnitChart(year, unitId);
    return {tahun: year, unitId: unitId, unitNama: unitNama, points: points};
}

# Resolves the effective report year: the current year when `tahun` is omitted, otherwise the given
# year after range-checking it.
#
# + tahun - the requested year, or ()
# + return - the effective year, a VALIDATION_ERROR AppError, or an error
function resolveTahun(int? tahun) returns int|error {
    if tahun is () {
        return currentProyekYear();
    }
    check validateProyekTahun(tahun);
    return tahun;
}

# Validates the triwulan parameter: must be 1..4.
#
# + triwulan - the requested quarter
# + return - a VALIDATION_ERROR AppError if out of range, else ()
function validateTriwulan(int triwulan) returns models:AppError? {
    if triwulan < 1 || triwulan > 4 {
        return utils:validationError("Triwulan harus di antara 1 dan 4");
    }
    return ();
}

# Validates that an optional unit filter references an existing (active) unit.
#
# + unitId - the optional unit filter
# + return - a VALIDATION_ERROR AppError if the unit doesn't exist, () otherwise, or an error
function ensureUnitFilter(int? unitId) returns models:AppError|error? {
    if unitId is () {
        return ();
    }
    boolean ok = check repositories:unitExistsActive(unitId);
    if !ok {
        return utils:validationError("Unit tidak ditemukan");
    }
    return ();
}
