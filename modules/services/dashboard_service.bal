import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;

# ===== Dashboard summary service (public, pre-login) =====

# Returns the top-level KPI cards (Total Proyek, Revenue Bulan Ini, Proyek Sedang Dikerjakan).
#
# + return - the dashboard summary, or an error
public function getDashboardSummary() returns models:DashboardSummary|error {
    return repositories:getDashboardSummary();
}
