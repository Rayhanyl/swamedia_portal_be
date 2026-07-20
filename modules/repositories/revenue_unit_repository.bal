import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Revenue Unit reports repository =====
#
# Read-only reporting queries combining the stored `target_revenue_unit` targets with the cash-basis
# actuals from the `v_realisasi_revenue_tw` view (sum of PARSIAL/FINAL `pencairan_tagihan` grouped by
# the proyek's unit and disbursement quarter). Parameterized `sql:ParameterizedQuery` templates only.
#
# The optional `unitId` filter is expressed with the `(${unitId}::bigint IS NULL OR ...)` idiom
# rather than dynamic query concatenation: binding a Ballerina `int?` sends SQL NULL when absent, so
# a single static query serves both "one unit" and "all units" — the NULL branch short-circuits the
# filter. The relevant-unit set for the full report / per-TW report is the UNION of units that have a
# target and units that have realisasi for the year (so a unit shows up even if only one side exists).

# Full Revenue Unit report for a year: one row per relevant unit with per-quarter target/realisasi,
# totals, and achievement percent.
#
# + tahun - the report year
# + unitId - optional single-unit filter (() = all units)
# + return - the report rows (ordered by unit name), or an error
public function findRevenueUnitReport(int tahun, int? unitId) returns models:RevenueUnitRow[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:RevenueUnitRow row in dbc->query(`
        WITH rel AS (
            SELECT unit_id FROM target_revenue_unit WHERE tahun = ${tahun}
            UNION
            SELECT unit_id FROM v_realisasi_revenue_tw WHERE tahun = ${tahun}
        ),
        r AS (
            SELECT unit_id,
                   COALESCE(SUM(realisasi) FILTER (WHERE triwulan = 1), 0) AS tw1,
                   COALESCE(SUM(realisasi) FILTER (WHERE triwulan = 2), 0) AS tw2,
                   COALESCE(SUM(realisasi) FILTER (WHERE triwulan = 3), 0) AS tw3,
                   COALESCE(SUM(realisasi) FILTER (WHERE triwulan = 4), 0) AS tw4
            FROM v_realisasi_revenue_tw WHERE tahun = ${tahun} GROUP BY unit_id
        )
        SELECT u.id AS "unitId", u.nama_unit AS "unitNama", ${tahun} AS tahun,
               COALESCE(tr.target_tw1, 0) AS "targetTw1",
               COALESCE(tr.target_tw2, 0) AS "targetTw2",
               COALESCE(tr.target_tw3, 0) AS "targetTw3",
               COALESCE(tr.target_tw4, 0) AS "targetTw4",
               COALESCE(tr.target_tw1,0) + COALESCE(tr.target_tw2,0)
                 + COALESCE(tr.target_tw3,0) + COALESCE(tr.target_tw4,0) AS "targetTotal",
               COALESCE(r.tw1, 0) AS "realisasiTw1",
               COALESCE(r.tw2, 0) AS "realisasiTw2",
               COALESCE(r.tw3, 0) AS "realisasiTw3",
               COALESCE(r.tw4, 0) AS "realisasiTw4",
               COALESCE(r.tw1,0) + COALESCE(r.tw2,0) + COALESCE(r.tw3,0) + COALESCE(r.tw4,0) AS "realisasiTotal",
               CASE WHEN (COALESCE(tr.target_tw1,0) + COALESCE(tr.target_tw2,0)
                          + COALESCE(tr.target_tw3,0) + COALESCE(tr.target_tw4,0)) > 0
                    THEN ROUND(
                         (COALESCE(r.tw1,0) + COALESCE(r.tw2,0) + COALESCE(r.tw3,0) + COALESCE(r.tw4,0))
                         / (COALESCE(tr.target_tw1,0) + COALESCE(tr.target_tw2,0)
                            + COALESCE(tr.target_tw3,0) + COALESCE(tr.target_tw4,0)) * 100, 2)
                    ELSE 0 END AS "pencapaianPersen"
        FROM rel
        JOIN unit u ON u.id = rel.unit_id
        LEFT JOIN target_revenue_unit tr ON tr.unit_id = u.id AND tr.tahun = ${tahun}
        LEFT JOIN r ON r.unit_id = u.id
        WHERE (${unitId}::bigint IS NULL OR u.id = ${unitId})
        ORDER BY u.nama_unit`, models:RevenueUnitRow)
        select row;
}

# Per-triwulan Revenue Unit report: one row per relevant unit with that quarter's target/realisasi
# and achievement percent.
#
# + tahun - the report year
# + triwulan - the quarter (1..4)
# + unitId - optional single-unit filter (() = all units)
# + return - the per-quarter report rows (ordered by unit name), or an error
public function findRevenueUnitTw(int tahun, int triwulan, int? unitId) returns models:RevenueUnitTwRow[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:RevenueUnitTwRow row in dbc->query(`
        WITH rel AS (
            SELECT unit_id FROM target_revenue_unit WHERE tahun = ${tahun}
            UNION
            SELECT unit_id FROM v_realisasi_revenue_tw WHERE tahun = ${tahun} AND triwulan = ${triwulan}
        ),
        base AS (
            SELECT u.id AS unit_id, u.nama_unit,
                   COALESCE(CASE ${triwulan} WHEN 1 THEN tr.target_tw1 WHEN 2 THEN tr.target_tw2
                                             WHEN 3 THEN tr.target_tw3 ELSE tr.target_tw4 END, 0) AS target,
                   COALESCE(r.realisasi, 0) AS realisasi
            FROM rel
            JOIN unit u ON u.id = rel.unit_id
            LEFT JOIN target_revenue_unit tr ON tr.unit_id = u.id AND tr.tahun = ${tahun}
            LEFT JOIN v_realisasi_revenue_tw r
                   ON r.unit_id = u.id AND r.tahun = ${tahun} AND r.triwulan = ${triwulan}
            WHERE (${unitId}::bigint IS NULL OR u.id = ${unitId})
        )
        SELECT unit_id AS "unitId", nama_unit AS "unitNama", ${tahun} AS tahun, ${triwulan} AS triwulan,
               target, realisasi,
               CASE WHEN target > 0 THEN ROUND(realisasi / target * 100, 2) ELSE 0 END AS "pencapaianPersen"
        FROM base
        ORDER BY nama_unit`, models:RevenueUnitTwRow)
        select row;
}

# Chart data for a year: exactly four points (TW1..TW4) of target vs realisasi, either for one unit
# or summed across all units. `generate_series(1,4)` guarantees all four quarters appear even when a
# quarter has no target/realisasi (zero-filled).
#
# + tahun - the chart year
# + unitId - optional single-unit filter (() = aggregate across all units)
# + return - the four quarter points (ordered TW1..TW4), or an error
public function findRevenueUnitChart(int tahun, int? unitId) returns models:RevenueUnitChartPoint[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:RevenueUnitChartPoint point in dbc->query(`
        WITH tgt AS (
            SELECT COALESCE(SUM(target_tw1),0) AS tw1, COALESCE(SUM(target_tw2),0) AS tw2,
                   COALESCE(SUM(target_tw3),0) AS tw3, COALESCE(SUM(target_tw4),0) AS tw4
            FROM target_revenue_unit
            WHERE tahun = ${tahun} AND (${unitId}::bigint IS NULL OR unit_id = ${unitId})
        ),
        rel AS (
            SELECT triwulan, COALESCE(SUM(realisasi),0) AS realisasi
            FROM v_realisasi_revenue_tw
            WHERE tahun = ${tahun} AND (${unitId}::bigint IS NULL OR unit_id = ${unitId})
            GROUP BY triwulan
        )
        SELECT g.triwulan AS "triwulan", ('TW' || g.triwulan) AS "label",
               CASE g.triwulan WHEN 1 THEN tgt.tw1 WHEN 2 THEN tgt.tw2
                               WHEN 3 THEN tgt.tw3 ELSE tgt.tw4 END AS "target",
               COALESCE(rel.realisasi, 0) AS "realisasi"
        FROM generate_series(1, 4) AS g(triwulan)
        CROSS JOIN tgt
        LEFT JOIN rel ON rel.triwulan = g.triwulan
        ORDER BY g.triwulan`, models:RevenueUnitChartPoint)
        select point;
}
