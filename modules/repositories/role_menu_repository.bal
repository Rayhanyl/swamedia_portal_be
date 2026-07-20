import ballerinax/postgresql;

# ===== RBAC — Role Menu assignment repository =====
#
# `role_menu` is a plain (role_id, menu_id) assignment table with no extra columns — the
# service layer folds it onto the full menu tree (see role_menu_service:getRoleMenus) to
# produce the checkbox-tree the "Role & Permission" UI edits and saves as a whole.

# Single-column row shapes for the id-list queries below — `dbc->query` needs a named record
# `typedesc` (an inline anonymous `record {| |}` literal cannot be passed as the rowType
# argument), so each single-column SELECT is mapped through one of these instead of a scalar type.
#
# + menuId - the menu id column value
type MenuIdRow record {|
    int menuId;
|};

type RoleIdRow record {|
    int roleId;
|};

# Fetches the set of menu ids currently assigned to a role.
#
# + roleId - the role id
# + return - the assigned menu ids, or an error
public function findAssignedMenuIds(int roleId) returns int[]|error {
    postgresql:Client dbc = check dbClient();
    MenuIdRow[] rows = check from MenuIdRow r in dbc->query(
            `SELECT menu_id AS "menuId" FROM role_menu WHERE role_id = ${roleId}`, MenuIdRow)
        select r;
    return from MenuIdRow r in rows select r.menuId;
}

# Fetches the distinct set of role ids that currently have the given menu assigned — used by
# menu_service:deleteMenu to know which roles' cached `role:{id}:menu` entry to invalidate
# once the menu (and its role_menu rows) are gone.
#
# + menuId - the menu id
# + return - the role ids currently assigned to this menu, or an error
public function findRoleIdsByMenuId(int menuId) returns int[]|error {
    postgresql:Client dbc = check dbClient();
    RoleIdRow[] rows = check from RoleIdRow r in dbc->query(
            `SELECT DISTINCT role_id AS "roleId" FROM role_menu WHERE menu_id = ${menuId}`, RoleIdRow)
        select r;
    return from RoleIdRow r in rows select r.roleId;
}

# Replaces every `role_menu` row for a role with exactly the given menu ids, atomically
# (delete-then-insert in one transaction).
#
# + roleId - the role id
# + menuIds - the full set of menu ids to assign (already validated by the service: each id
#             exists in `menu` and appears at most once)
# + return - an error if the transaction failed
public function replaceRoleMenus(int roleId, int[] menuIds) returns error? {
    postgresql:Client dbc = check dbClient();
    transaction {
        _ = check dbc->execute(`DELETE FROM role_menu WHERE role_id = ${roleId}`);
        foreach int menuId in menuIds {
            _ = check dbc->execute(`INSERT INTO role_menu (role_id, menu_id) VALUES (${roleId}, ${menuId})`);
        }
        check commit;
    }
}
