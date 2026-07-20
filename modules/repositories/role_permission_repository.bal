import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== RBAC — Role Permission matrix repository =====
#
# `role_permission` is edited as a whole matrix per role (one row per modul, LEFT JOINed
# against the fixed `modul` master so every module always appears — even one this role has no
# row for yet, defaulted to no access / scope ALL). Saving the matrix replaces the role's
# entire row set in one transaction rather than diffing individual cells.

# Builds the full permission matrix for a role: every modul row, with the role's actual
# grants where a `role_permission` row exists, or all-false/scope ALL defaults otherwise.
#
# + roleId - the role id
# + return - the matrix rows ordered by modul.urutan, or an error
public function findRolePermissionMatrix(int roleId) returns models:RolePermissionItem[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:RolePermissionItem i in dbc->query(`
            SELECT m.id AS "modulId", m.kode_modul AS "kodeModul", m.nama_modul AS "namaModul",
                   COALESCE(rp.can_create, false) AS "canCreate",
                   COALESCE(rp.can_read, false) AS "canRead",
                   COALESCE(rp.can_update, false) AS "canUpdate",
                   COALESCE(rp.can_delete, false) AS "canDelete",
                   COALESCE(rp.can_approve, false) AS "canApprove",
                   COALESCE(rp.can_export, false) AS "canExport",
                   COALESCE(rp.scope, 'ALL') AS scope
            FROM modul m
            LEFT JOIN role_permission rp ON rp.modul_id = m.id AND rp.role_id = ${roleId}
            ORDER BY m.urutan ASC`, models:RolePermissionItem)
        select i;
}

# Replaces every `role_permission` row for a role with exactly the given items, atomically
# (delete-then-insert in one transaction — a partial write would leave the matrix in a mixed
# old/new state).
#
# + roleId - the role id
# + items - the full set of per-modul grants to persist (already validated by the service:
#           each modulId exists in `modul` and appears at most once)
# + subject - the caller's `sub` claim, stored as created_by on every inserted row
# + return - an error if the transaction failed
public function replaceRolePermissions(int roleId, models:RolePermissionUpdateItem[] items, string subject)
        returns error? {
    postgresql:Client dbc = check dbClient();
    transaction {
        _ = check dbc->execute(`DELETE FROM role_permission WHERE role_id = ${roleId}`);
        foreach models:RolePermissionUpdateItem item in items {
            _ = check dbc->execute(`
                INSERT INTO role_permission
                    (role_id, modul_id, can_create, can_read, can_update, can_delete,
                     can_approve, can_export, scope, created_by)
                VALUES (${roleId}, ${item.modulId}, ${item.canCreate}, ${item.canRead}, ${item.canUpdate},
                        ${item.canDelete}, ${item.canApprove}, ${item.canExport}, ${item.scope}, ${subject})`);
        }
        check commit;
    }
}
