import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;

# ===== RBAC — Modul service =====
#
# Read-only master: no create/update/delete. Sole purpose is to back the column headers of
# the Role & Permission matrix UI (`GET /api/v1/master/modul`).

# + return - all modul rows ordered for display, or an error
public function getModul() returns models:Modul[]|error {
    return repositories:findAllModul();
}
