import ballerina/log;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== RBAC — Menu service =====
#
# Business rules and validation for the navigation menu tree. `menu` has no audit columns and
# no is_deleted, so create/update/delete map to plain hard operations at the repository layer.

# Maximum ancestor-chain depth walked when checking for circular references — a safety valve
# against already-corrupt data, far above any realistic menu depth (mirrors unit_service).
const int MENU_MAX_TREE_DEPTH = 10000;

# TTL safety net for a role's cached filtered menu tree (`role:{id}:menu`). Freshness normally
# comes from menu_service/role_menu_service invalidating the key whenever a menu or a role's
# assignment changes; the TTL only bounds staleness if an invalidation is ever missed.
const int ROLE_MENU_CACHE_TTL_SECONDS = 300;

# Returns the navigation menu tree for the currently logged-in user, filtered to exactly the
# menus their role has been assigned (and that are still AKTIF). This is what the frontend renders
# as the sidebar after login — the role is resolved from the caller's `swaportal_role_id` claim
# (reusing resolveRoleId from the authorization service), never a client-supplied id. Cache-aside
# on Redis `role:{id}:menu` (the same key role_menu_service/menu_service invalidate on change).
#
# + accessToken - the caller's raw Bearer access token
# + return - the role's assigned menu tree, a FORBIDDEN AppError if the account has no role, or an error
public function getMyMenu(string accessToken) returns models:MenuTreeNode[]|error {
    int|models:AppError roleId = resolveRoleId(accessToken);
    if roleId is models:AppError {
        return roleId;
    }

    string cacheKey = "role:" + roleId.toString() + ":menu";
    json|error cached = repositories:cacheGet(cacheKey);
    if cached is json && cached !is () {
        models:MenuTreeNode[]|error fromCache = cached.cloneWithType();
        if fromCache is models:MenuTreeNode[] {
            return fromCache;
        }
        log:printError("role menu cache decode failed, reloading from DB", fromCache);
    } else if cached is error {
        log:printError("role menu cache read failed, falling back to DB", cached);
    }

    models:Menu[] menus = check repositories:findAllMenus();
    int[] assignedIds = check repositories:findAssignedMenuIds(roleId);
    models:MenuTreeNode[] tree = buildMyMenuTree(menus, assignedIds);

    error? cacheErr = repositories:cacheSet(cacheKey, tree.toJson(), ttlSeconds = ROLE_MENU_CACHE_TTL_SECONDS);
    if cacheErr is error {
        log:printError("role menu cache write failed", cacheErr);
    }
    return tree;
}

# Builds the filtered menu tree for a role: a node is visible only if it is assigned to the role
# AND still AKTIF; the AKTIF ancestor chain of each visible node is pulled in too so the tree keeps
# its shape (an inactive ancestor cuts the branch above it). Reuses buildMenuTree on the survivors.
#
# + menus - the full flat menu list
# + assignedIds - the menu ids assigned to the role
# + return - the filtered root nodes
function buildMyMenuTree(models:Menu[] menus, int[] assignedIds) returns models:MenuTreeNode[] {
    map<models:Menu> byId = {};
    foreach models:Menu m in menus {
        byId[m.id.toString()] = m;
    }
    map<boolean> assignedSet = {};
    foreach int id in assignedIds {
        assignedSet[id.toString()] = true;
    }

    map<boolean> visible = {};
    foreach models:Menu m in menus {
        if !assignedSet.hasKey(m.id.toString()) || m.status != "AKTIF" {
            continue;
        }
        models:Menu? current = m;
        int depth = 0;
        while current is models:Menu {
            if current.status != "AKTIF" {
                break;
            }
            visible[current.id.toString()] = true;
            int? parentId = current.parentId;
            if parentId is int && byId.hasKey(parentId.toString()) {
                current = byId.get(parentId.toString());
            } else {
                current = ();
            }
            depth += 1;
            if depth > MENU_MAX_TREE_DEPTH {
                break;
            }
        }
    }

    models:Menu[] visibleMenus = from models:Menu m in menus
        where visible.hasKey(m.id.toString())
        select m;
    return buildMenuTree(visibleMenus);
}

# Lists menu rows with optional filters and pagination.
#
# + search - optional ILIKE filter on kode_menu or nama_menu
# + status - optional status filter (AKTIF / TIDAK_AKTIF)
# + parentId - optional filter selecting only children of this menu id
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of menu rows plus pagination metadata, or an error
public function getMenus(string? search, string? status, int? parentId, int page, int 'limit)
        returns models:MenuListResult|error {
    if status is string && status.trim().length() > 0 && !isValidMenuStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Menu[] items; int totalItems;|} result =
        check repositories:findMenus(search, status, parentId, safeLimit, offset);

    int totalItems = result.totalItems;
    int totalPages = totalItems == 0 ? 0 : (totalItems + safeLimit - 1) / safeLimit;
    models:Pagination pagination = {
        page: safePage,
        'limit: safeLimit,
        totalItems: totalItems,
        totalPages: totalPages
    };
    return {items: result.items, pagination: pagination};
}

# Fetches a single menu by id.
#
# + id - the menu id
# + return - the menu, or a NOT_FOUND AppError if it does not exist, or an error
public function getMenuById(int id) returns models:Menu|error {
    models:Menu? menu = check repositories:findMenuById(id);
    if menu is () {
        return utils:notFoundError("Menu dengan id " + id.toString() + " tidak ditemukan");
    }
    return menu;
}

# Builds the full menu hierarchy from a single flat read (mirrors unit_service:getUnitTree —
# no recursive SQL, the tree is assembled in memory).
#
# + return - the root nodes of the menu tree, or an error
public function getMenuTree() returns models:MenuTreeNode[]|error {
    models:Menu[] menus = check repositories:findAllMenus();
    return buildMenuTree(menus);
}

function buildMenuTree(models:Menu[] menus) returns models:MenuTreeNode[] {
    map<models:MenuTreeNode> nodeById = {};
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
            children: []
        };
    }

    models:MenuTreeNode[] roots = [];
    foreach models:Menu m in menus {
        models:MenuTreeNode node = nodeById.get(m.id.toString());
        int? parentId = m.parentId;
        if parentId is int && nodeById.hasKey(parentId.toString()) {
            models:MenuTreeNode parent = nodeById.get(parentId.toString());
            parent.children.push(node);
        } else {
            roots.push(node);
        }
    }
    return roots;
}

# Creates a new menu after validating kode/nama/status and the parent reference.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - the created menu, a VALIDATION_ERROR/CONFLICT AppError, or an error
public function createMenu(models:MenuCreateRequest payload, string subject) returns models:Menu|error {
    string kodeMenu = payload.kodeMenu.trim();
    check validateKodeMenu(kodeMenu);
    string namaMenu = payload.namaMenu.trim();
    check validateNamaMenu(namaMenu);
    string? path = check normalizeOptionalField(payload?.path, 150, "Path");
    string? icon = check normalizeOptionalField(payload?.icon, 50, "Icon");
    int urutan = payload?.urutan ?: 0;

    string status = payload?.status ?: "AKTIF";
    if !isValidMenuStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int? parentId = payload?.parentId;
    if parentId is int {
        boolean exists = check repositories:menuExistsById(parentId);
        if !exists {
            return utils:validationError("Menu induk tidak ditemukan");
        }
    }

    boolean duplicate = check repositories:kodeMenuExists(kodeMenu, 0);
    if duplicate {
        return utils:conflictError("Kode menu sudah digunakan");
    }

    models:Menu created = check repositories:insertMenu(parentId, kodeMenu, namaMenu, path, icon, urutan, status);
    logAudit("menu", created.id.toString(), "CREATE", (), created.toJson(), subject);
    return created;
}

# Updates an existing menu. Validates the parent reference and guards against circular
# references before writing.
#
# + id - the menu id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - the updated menu, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateMenu(int id, models:MenuUpdateRequest payload, string subject) returns models:Menu|error {
    string kodeMenu = payload.kodeMenu.trim();
    check validateKodeMenu(kodeMenu);
    string namaMenu = payload.namaMenu.trim();
    check validateNamaMenu(namaMenu);
    string? path = check normalizeOptionalField(payload?.path, 150, "Path");
    string? icon = check normalizeOptionalField(payload?.icon, 50, "Icon");

    if !isValidMenuStatus(payload.status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    models:Menu? existing = check repositories:findMenuById(id);
    if existing is () {
        return utils:notFoundError("Menu dengan id " + id.toString() + " tidak ditemukan");
    }

    int? parentId = payload?.parentId;
    if parentId is int {
        if parentId == id {
            return utils:validationError("Menu induk tidak boleh menunjuk ke dirinya sendiri");
        }
        boolean exists = check repositories:menuExistsById(parentId);
        if !exists {
            return utils:validationError("Menu induk tidak ditemukan");
        }
        boolean circular = check wouldCreateCircularMenuReference(id, parentId);
        if circular {
            return utils:validationError("Parent menu tidak boleh membentuk referensi melingkar");
        }
    }

    boolean duplicate = check repositories:kodeMenuExists(kodeMenu, id);
    if duplicate {
        return utils:conflictError("Kode menu sudah digunakan");
    }

    models:Menu? updated = check repositories:updateMenu(
            id, parentId, kodeMenu, namaMenu, path, icon, payload.urutan, payload.status);
    if updated is () {
        return utils:notFoundError("Menu dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("menu", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject);
    return updated;
}

# Deletes a menu after ensuring it exists and has no active sub-menu, then invalidates the
# `role:{id}:menu` cache of every role that had this menu assigned (its tree just changed).
#
# + id - the menu id to delete
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteMenu(int id, string subject) returns error? {
    models:Menu? existing = check repositories:findMenuById(id);
    if existing is () {
        return utils:notFoundError("Menu dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean hasChildren = check repositories:hasChildMenus(id);
    if hasChildren {
        return utils:conflictError("Menu tidak dapat dihapus karena masih memiliki sub-menu");
    }

    int[] affectedRoleIds = check repositories:findRoleIdsByMenuId(id);

    boolean deleted = check repositories:deleteMenu(id);
    if !deleted {
        return utils:notFoundError("Menu dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("menu", id.toString(), "DELETE", existing.toJson(), (), subject);

    foreach int roleId in affectedRoleIds {
        error? cacheErr = repositories:cacheDelete("role:" + roleId.toString() + ":menu");
        if cacheErr is error {
            log:printError("Failed to invalidate role menu cache after menu delete", cacheErr);
        }
    }
    return ();
}

function validateKodeMenu(string kodeMenu) returns models:AppError? {
    if kodeMenu.length() < 1 || kodeMenu.length() > 50 {
        return utils:validationError("Kode menu wajib diisi, panjang maksimal 50 karakter");
    }
    return ();
}

function validateNamaMenu(string namaMenu) returns models:AppError? {
    if namaMenu.length() < 1 || namaMenu.length() > 100 {
        return utils:validationError("Nama menu wajib diisi, panjang maksimal 100 karakter");
    }
    return ();
}

# Trims an optional field and normalizes a blank result to (); rejects a value exceeding
# `maxLength` (matches the corresponding DB column width) with a VALIDATION_ERROR.
#
# + value - the optional raw field value
# + maxLength - the maximum allowed length after trimming
# + label - the field label used in the validation error message
# + return - the trimmed value, () if nil/blank, or a VALIDATION_ERROR AppError if too long
function normalizeOptionalField(string? value, int maxLength, string label) returns string?|models:AppError {
    if value is () {
        return ();
    }
    string trimmed = value.trim();
    if trimmed.length() == 0 {
        return ();
    }
    if trimmed.length() > maxLength {
        return utils:validationError(label + " maksimal " + maxLength.toString() + " karakter");
    }
    return trimmed;
}

function isValidMenuStatus(string status) returns boolean {
    return status == "AKTIF" || status == "TIDAK_AKTIF";
}

# Returns whether making `newParentId` the parent of `menuId` would create a cycle (mirrors
# unit_service:wouldCreateCircularReference).
#
# + menuId - the menu being reparented
# + newParentId - the proposed new parent menu id
# + return - true if this would create a circular reference, or an error
function wouldCreateCircularMenuReference(int menuId, int newParentId) returns boolean|error {
    int? current = newParentId;
    int depth = 0;
    while current is int {
        if current == menuId {
            return true;
        }
        models:Menu? ancestor = check repositories:findMenuById(current);
        if ancestor is () {
            break;
        }
        current = ancestor.parentId;
        depth += 1;
        if depth > MENU_MAX_TREE_DEPTH {
            return error("Circular reference walk exceeded maximum depth for menu " + menuId.toString());
        }
    }
    return false;
}
