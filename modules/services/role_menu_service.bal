import ballerina/log;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== RBAC — Role Menu assignment service =====
#
# Same whole-matrix editing model as role_permission (see role_permission_service): GET
# returns the full menu tree with an `assigned` flag per node, PUT replaces the role's
# assigned-menu set wholesale. Saving invalidates the `role:{id}:menu` Redis key the auth
# middleware reads (schema implementation note #7); a failed invalidation is logged, not fatal.

# Fetches the full menu tree annotated with which nodes this role has assigned.
#
# + roleId - the role id
# + return - the role's menu tree with assigned flags, a NOT_FOUND AppError if the role
#            doesn't exist, or an error
public function getRoleMenus(int roleId) returns models:RoleMenuMatrix|error {
    models:Role? role = check repositories:findRoleById(roleId);
    if role is () {
        return utils:notFoundError("Role dengan id " + roleId.toString() + " tidak ditemukan");
    }

    models:Menu[] menus = check repositories:findAllMenus();
    int[] assignedIds = check repositories:findAssignedMenuIds(roleId);
    map<boolean> assignedSet = {};
    foreach int id in assignedIds {
        assignedSet[id.toString()] = true;
    }

    models:RoleMenuTreeNode[] tree = buildRoleMenuTree(menus, assignedSet);
    return {roleId: role.id, kodeRole: role.kodeRole, namaRole: role.namaRole, items: tree};
}

function buildRoleMenuTree(models:Menu[] menus, map<boolean> assignedSet) returns models:RoleMenuTreeNode[] {
    map<models:RoleMenuTreeNode> nodeById = {};
    foreach models:Menu m in menus {
        nodeById[m.id.toString()] = {
            id: m.id,
            parentId: m.parentId,
            kodeMenu: m.kodeMenu,
            namaMenu: m.namaMenu,
            path: m.path,
            icon: m.icon,
            urutan: m.urutan,
            status: m.status,
            assigned: assignedSet.hasKey(m.id.toString()),
            children: []
        };
    }

    models:RoleMenuTreeNode[] roots = [];
    foreach models:Menu m in menus {
        models:RoleMenuTreeNode node = nodeById.get(m.id.toString());
        int? parentId = m.parentId;
        if parentId is int && nodeById.hasKey(parentId.toString()) {
            models:RoleMenuTreeNode parent = nodeById.get(parentId.toString());
            parent.children.push(node);
        } else {
            roots.push(node);
        }
    }
    return roots;
}

# Replaces the role's entire assigned-menu set. Every id must exist in `menu` and appear at
# most once.
#
# + roleId - the role id
# + payload - the full set of menu ids to assign
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - the saved menu tree with assigned flags, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function replaceRoleMenus(int roleId, models:RoleMenuUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:RoleMenuMatrix|error {
    models:Role? role = check repositories:findRoleById(roleId);
    if role is () {
        return utils:notFoundError("Role dengan id " + roleId.toString() + " tidak ditemukan");
    }

    map<boolean> seenIds = {};
    foreach int menuId in payload.menuIds {
        string key = menuId.toString();
        if seenIds.hasKey(key) {
            return utils:validationError("Menu dengan id " + key + " muncul lebih dari sekali");
        }
        seenIds[key] = true;
        boolean exists = check repositories:menuExistsById(menuId);
        if !exists {
            return utils:validationError("Menu dengan id " + key + " tidak ditemukan");
        }
    }

    int[] oldMenuIds = check repositories:findAssignedMenuIds(roleId);
    check repositories:replaceRoleMenus(roleId, payload.menuIds);

    error? cacheErr = repositories:cacheDelete("role:" + roleId.toString() + ":menu");
    if cacheErr is error {
        log:printError("Failed to invalidate role menu cache", cacheErr);
    }

    logAudit("role_menu", roleId.toString(), "UPDATE", oldMenuIds.toJson(), payload.menuIds.toJson(), subject, ipAddress);
    return getRoleMenus(roleId);
}
