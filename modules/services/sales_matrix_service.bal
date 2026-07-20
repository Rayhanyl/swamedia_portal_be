import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Sales Matrix / Pencapaian Sales Unit service =====
#
# Read-only reporting on top of `target_sales_unit` (targets) and the `v_realisasi_sales_tw` view
# (deal-basis actuals) — the sales twin of revenue_unit_service. Domain failures are
# `models:AppError`; infrastructure failures propagate as plain `error`. Reuses the module-scoped
# `resolveTahun`, `validateTriwulan` and `ensureUnitFilter` helpers from revenue_unit_service rather
# than redeclaring them.

# Full Sales Matrix report (target vs realisasi per unit) for a year.
#
# + tahun - the report year, or () for the current year
# + unitId - optional single-unit filter
# + return - the report rows, a VALIDATION_ERROR AppError, or an error
public function getSalesMatrixReport(int? tahun, int? unitId) returns models:SalesUnitRow[]|error {
    int year = check resolveTahun(tahun);
    check ensureUnitFilter(unitId);
    return repositories:findSalesMatrixReport(year, unitId);
}

# Per-triwulan Sales Matrix report for a year.
#
# + tahun - the report year, or () for the current year
# + triwulan - the quarter (1..4)
# + unitId - optional single-unit filter
# + return - the per-quarter report rows, a VALIDATION_ERROR AppError, or an error
public function getSalesMatrixTw(int? tahun, int triwulan, int? unitId) returns models:SalesUnitTwRow[]|error {
    int year = check resolveTahun(tahun);
    check validateTriwulan(triwulan);
    check ensureUnitFilter(unitId);
    return repositories:findSalesMatrixTw(year, triwulan, unitId);
}

# Sales Matrix chart (four quarter points of target vs realisasi) for a year, optionally scoped to a
# single unit.
#
# + tahun - the chart year, or () for the current year
# + unitId - optional single-unit filter (() = aggregate across all units)
# + return - the assembled chart, a VALIDATION_ERROR AppError, or an error
public function getSalesMatrixChart(int? tahun, int? unitId) returns models:SalesUnitChart|error {
    int year = check resolveTahun(tahun);

    string? unitNama = ();
    if unitId is int {
        models:Unit? unit = check repositories:findUnitById(unitId);
        if unit is () {
            return utils:validationError("Unit tidak ditemukan");
        }
        unitNama = unit.namaUnit;
    }

    models:SalesUnitChartPoint[] points = check repositories:findSalesMatrixChart(year, unitId);
    return {tahun: year, unitId: unitId, unitNama: unitNama, points: points};
}
