import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Cashflow report repository =====
#
# Read-only, company-wide cash-flow reporting for a year, aligned with the `v_posisi_kas` view's
# inflow/outflow definitions but broken down per month:
#   inflow  = PARSIAL/FINAL pencairan_tagihan (by tanggal_pencairan month)
#   outflow = APPROVED+realized pembayaran + pengeluaran_perusahaan (by tanggal_realisasi month)
# `generate_series(1,12)` guarantees all twelve months appear (zero-filled). Parameterized templates
# only. Kept company-wide (no unit dimension) to match the company-level posisi-kas semantics.

# Twelve monthly inflow/outflow/net rows for a year.
#
# + tahun - the report year
# + return - the twelve monthly rows (ordered Jan..Des), or an error
public function findCashflowMonths(int tahun) returns models:CashflowMonth[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:CashflowMonth row in dbc->query(`
        WITH inflow AS (
            SELECT EXTRACT(MONTH FROM pt.tanggal_pencairan)::int AS bulan, SUM(pt.nilai) AS total
            FROM pencairan_tagihan pt
            WHERE pt.status IN ('PARSIAL','FINAL') AND pt.is_deleted = false
              AND EXTRACT(YEAR FROM pt.tanggal_pencairan) = ${tahun}
            GROUP BY 1
        ),
        outflow AS (
            SELECT bulan, SUM(total) AS total FROM (
                SELECT EXTRACT(MONTH FROM tanggal_realisasi)::int AS bulan, SUM(nilai) AS total
                FROM pembayaran
                WHERE status = 'APPROVED' AND is_deleted = false AND tanggal_realisasi IS NOT NULL
                  AND EXTRACT(YEAR FROM tanggal_realisasi) = ${tahun}
                GROUP BY 1
                UNION ALL
                SELECT EXTRACT(MONTH FROM tanggal_realisasi)::int AS bulan, SUM(nilai) AS total
                FROM pengeluaran_perusahaan
                WHERE status = 'APPROVED' AND is_deleted = false AND tanggal_realisasi IS NOT NULL
                  AND EXTRACT(YEAR FROM tanggal_realisasi) = ${tahun}
                GROUP BY 1
            ) o GROUP BY bulan
        )
        SELECT g.bulan AS "bulan",
               (ARRAY['Jan','Feb','Mar','Apr','Mei','Jun','Jul','Agu','Sep','Okt','Nov','Des'])[g.bulan] AS "label",
               COALESCE(i.total, 0) AS "inflow",
               COALESCE(o.total, 0) AS "outflow",
               COALESCE(i.total, 0) - COALESCE(o.total, 0) AS "net"
        FROM generate_series(1, 12) AS g(bulan)
        LEFT JOIN inflow i ON i.bulan = g.bulan
        LEFT JOIN outflow o ON o.bulan = g.bulan
        ORDER BY g.bulan`, models:CashflowMonth)
        select row;
}

# Current cash position from `v_posisi_kas` (latest saldo awal + inflow - outflow). Returns () when
# no saldo awal kas has been recorded yet (the view yields a NULL posisi_kas in that case).
#
# + return - the current cash position, () when there is no saldo awal, or an error
public function findPosisiKasTerkini() returns decimal?|error {
    postgresql:Client dbc = check dbClient();
    decimal? posisi = check dbc->queryRow(`SELECT posisi_kas FROM v_posisi_kas`);
    return posisi;
}
