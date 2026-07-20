import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;

# ===== Cashflow report service =====
#
# Read-only, company-wide cash-flow reporting. Domain failures are `models:AppError`; infrastructure
# failures propagate as plain `error`. `tahun` defaults to the current year and is range-checked via
# the module-scoped `resolveTahun` helper (revenue_unit_service). The report assembles the twelve
# monthly inflow/outflow/net rows, the year totals, and the current cash position (v_posisi_kas).

# Full Cashflow report for a year: twelve monthly rows + totals + current cash position.
#
# + tahun - the report year, or () for the current year
# + return - the assembled report, a VALIDATION_ERROR AppError, or an error
public function getCashflowReport(int? tahun) returns models:CashflowReport|error {
    int year = check resolveTahun(tahun);

    models:CashflowMonth[] months = check repositories:findCashflowMonths(year);
    decimal totalInflow = 0d;
    decimal totalOutflow = 0d;
    foreach models:CashflowMonth m in months {
        totalInflow += m.inflow;
        totalOutflow += m.outflow;
    }
    decimal? posisiKas = check repositories:findPosisiKasTerkini();

    return {
        tahun: year,
        months: months,
        totalInflow: totalInflow,
        totalOutflow: totalOutflow,
        netTotal: totalInflow - totalOutflow,
        posisiKasTerkini: posisiKas
    };
}

# Cashflow chart for a year: twelve monthly inflow-vs-outflow points.
#
# + tahun - the chart year, or () for the current year
# + return - the twelve chart points (Jan..Des), a VALIDATION_ERROR AppError, or an error
public function getCashflowChart(int? tahun) returns models:CashflowChartPoint[]|error {
    int year = check resolveTahun(tahun);
    models:CashflowMonth[] months = check repositories:findCashflowMonths(year);
    return from models:CashflowMonth m in months
        select {bulan: m.bulan, label: m.label, inflow: m.inflow, outflow: m.outflow};
}
