import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== RBAC — Modul repository =====
#
# Read-only access to `modul`, the fixed master list of application modules referenced by
# `role_permission` (A13 in the schema). Seeded at schema build time; no create/update/delete.

# Fetches every modul row, ordered for UI display.
#
# + return - all modul rows, or an error
public function findAllModul() returns models:Modul[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:Modul m in dbc->query(`
            SELECT id, kode_modul AS "kodeModul", nama_modul AS "namaModul", urutan
            FROM modul ORDER BY urutan ASC`, models:Modul)
        select m;
}
