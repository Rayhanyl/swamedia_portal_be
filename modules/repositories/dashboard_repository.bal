import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Dashboard summary repository (public, pre-login) =====

# Fetches the three top-level KPI cards in a single round trip via scalar subqueries.
#
# Schema v2.1 note: `tagihan` no longer carries `nilai_cair`/`tanggal_cair` — actual revenue is
# recorded per-disbursement in `pencairan_tagihan` (mirrors view `v_realisasi_revenue_tw`, just
# scoped to the current calendar month instead of a quarter). Likewise `proyek.status` has no
# 'ACTIVE' value (see `ck_proyek_status`); "sedang dikerjakan" is a won deal
# (`status = 'DEAL_KONTRAK'`) whose `target_selesai` hasn't passed yet (or is unset).
#
# + return - the dashboard summary, or an error
public function getDashboardSummary() returns models:DashboardSummary|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery query = `SELECT
            (SELECT COUNT(*) FROM proyek WHERE is_deleted = false) AS "totalProyek",
            (SELECT COALESCE(SUM(pt.nilai), 0)
                FROM pencairan_tagihan pt
                JOIN tagihan t ON t.id = pt.tagihan_id AND t.is_deleted = false
                WHERE pt.is_deleted = false
                AND pt.status IN ('PARSIAL', 'FINAL')
                AND pt.tanggal_pencairan >= date_trunc('month', CURRENT_DATE)
                AND pt.tanggal_pencairan < date_trunc('month', CURRENT_DATE) + INTERVAL '1 month'
            ) AS "revenueBulanIni",
            (SELECT COUNT(*) FROM proyek
                WHERE is_deleted = false
                AND status = 'DEAL_KONTRAK'
                AND (target_selesai IS NULL OR target_selesai >= CURRENT_DATE)
            ) AS "proyekSedangDikerjakan"`;

    models:DashboardSummary summary = check dbc->queryRow(query);
    return summary;
}
