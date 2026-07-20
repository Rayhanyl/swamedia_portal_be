import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== RBAC — Menu repository =====
#
# All access to the `menu` table. `menu` carries no audit columns and no `is_deleted` — it is
# a lean, purely structural navigation tree (A15 in the schema), so create/update/delete here
# are plain hard operations. Deleting a menu that still has role_menu assignments would fail
# on the FK constraint, so `deleteMenu` clears those rows first inside a transaction (the
# service layer separately blocks deleting a menu that still has active children).

# Fetches one page of menu rows matching the optional search/status/parent filters, plus the
# total matching count. `search` matches kode_menu OR nama_menu (ILIKE).
#
# + search - optional case-insensitive filter on kode_menu or nama_menu
# + status - optional exact filter on status (AKTIF / TIDAK_AKTIF)
# + parentId - optional filter selecting only children of this menu id
# + limit - page size
# + offset - rows to skip
# + return - the page items and the total matching count, or an error
public function findMenus(string? search, string? status, int? parentId, int 'limit, int offset)
        returns record {|models:Menu[] items; int totalItems;|}|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] conditions = [];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        conditions.push(` AND (kode_menu ILIKE ${pattern} OR nama_menu ILIKE ${pattern})`);
    }
    if status is string && status.trim().length() > 0 {
        conditions.push(` AND status = ${status}`);
    }
    if parentId is int {
        conditions.push(` AND parent_id = ${parentId}`);
    }

    sql:ParameterizedQuery[] selectParts = [
        `SELECT id, parent_id AS "parentId", kode_menu AS "kodeMenu", nama_menu AS "namaMenu",
                path, icon, urutan, status
         FROM menu WHERE 1=1`
    ];
    foreach sql:ParameterizedQuery c in conditions {
        selectParts.push(c);
    }
    selectParts.push(` ORDER BY urutan ASC, id ASC LIMIT ${'limit} OFFSET ${offset}`);
    sql:ParameterizedQuery selectQuery = sql:queryConcat(...selectParts);

    models:Menu[] items = check from models:Menu m in dbc->query(selectQuery, models:Menu)
        select m;

    sql:ParameterizedQuery[] countParts = [`SELECT count(*) FROM menu WHERE 1=1`];
    foreach sql:ParameterizedQuery c in conditions {
        countParts.push(c);
    }
    sql:ParameterizedQuery countQuery = sql:queryConcat(...countParts);
    int totalItems = check dbc->queryRow(countQuery);

    return {items: items, totalItems: totalItems};
}

# Fetches a single menu by id.
#
# + id - the menu id
# + return - the menu, `()` if not found, or an error
public function findMenuById(int id) returns models:Menu?|error {
    postgresql:Client dbc = check dbClient();
    models:Menu|sql:Error result = dbc->queryRow(`
        SELECT id, parent_id AS "parentId", kode_menu AS "kodeMenu", nama_menu AS "namaMenu",
               path, icon, urutan, status
        FROM menu WHERE id = ${id}`, models:Menu);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Fetches every menu row, ordered for display — the single flat read the service layer folds
# into a tree (mirrors `unit_repository:findAllActiveUnits`).
#
# + return - all menu rows, or an error
public function findAllMenus() returns models:Menu[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:Menu m in dbc->query(`
            SELECT id, parent_id AS "parentId", kode_menu AS "kodeMenu", nama_menu AS "namaMenu",
                   path, icon, urutan, status
            FROM menu ORDER BY urutan ASC, id ASC`, models:Menu)
        select m;
}

# Returns whether a menu with the given id exists (used to validate parentId references and
# the menuIds sent to the role-menu matrix endpoint).
#
# + id - the menu id to check
# + return - true if a menu with that id exists, or an error
public function menuExistsById(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM menu WHERE id = ${id}`);
    return count > 0;
}

# Returns whether another menu already uses the given kode_menu (NOT NULL UNIQUE in the DB).
# `excludeId` skips a specific row (pass 0 on insert; the target id on update).
#
# + kodeMenu - the code to check
# + excludeId - a menu id to exclude from the check (0 = none)
# + return - true if a conflicting kode_menu exists, or an error
public function kodeMenuExists(string kodeMenu, int excludeId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`
        SELECT count(*) FROM menu WHERE kode_menu = ${kodeMenu} AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether the given menu still has any child menu row (blocks delete).
#
# + id - the parent menu id
# + return - true if at least one menu references this as parent, or an error
public function hasChildMenus(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(`SELECT count(*) FROM menu WHERE parent_id = ${id}`);
    return count > 0;
}

# Inserts a new menu and returns the created row (via RETURNING).
#
# + parentId - parent menu id, or () for a top-level menu
# + kodeMenu - unique menu code
# + namaMenu - menu label
# + path - optional frontend route
# + icon - optional icon identifier
# + urutan - display order
# + status - AKTIF / TIDAK_AKTIF
# + return - the created menu, or an error
public function insertMenu(int? parentId, string kodeMenu, string namaMenu, string? path, string? icon,
        int urutan, string status) returns models:Menu|error {
    postgresql:Client dbc = check dbClient();
    models:Menu created = check dbc->queryRow(`
        INSERT INTO menu (parent_id, kode_menu, nama_menu, path, icon, urutan, status)
        VALUES (${parentId}, ${kodeMenu}, ${namaMenu}, ${path}, ${icon}, ${urutan}, ${status})
        RETURNING id, parent_id AS "parentId", kode_menu AS "kodeMenu", nama_menu AS "namaMenu",
                  path, icon, urutan, status`);
    return created;
}

# Updates a menu and returns the updated row (via RETURNING).
#
# + id - the menu id
# + parentId - new parent menu id, or () to clear it
# + kodeMenu - new unique menu code
# + namaMenu - new menu label
# + path - new frontend route, or ()
# + icon - new icon identifier, or ()
# + urutan - new display order
# + status - new status
# + return - the updated menu, `()` if the menu does not exist, or an error
public function updateMenu(int id, int? parentId, string kodeMenu, string namaMenu, string? path, string? icon,
        int urutan, string status) returns models:Menu?|error {
    postgresql:Client dbc = check dbClient();
    models:Menu|sql:Error updated = dbc->queryRow(`
        UPDATE menu SET parent_id = ${parentId}, kode_menu = ${kodeMenu}, nama_menu = ${namaMenu},
               path = ${path}, icon = ${icon}, urutan = ${urutan}, status = ${status}
        WHERE id = ${id}
        RETURNING id, parent_id AS "parentId", kode_menu AS "kodeMenu", nama_menu AS "namaMenu",
                  path, icon, urutan, status`, models:Menu);
    if updated is sql:NoRowsError {
        return ();
    }
    return updated;
}

# Hard-deletes a menu, clearing its role_menu assignment rows first inside a single
# transaction (role_menu.menu_id has no ON DELETE CASCADE). The service layer is responsible
# for blocking deletion while the menu still has active children.
#
# + id - the menu id
# + return - true if the menu row was deleted, false if it did not exist, or an error
public function deleteMenu(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean deleted = false;
    transaction {
        _ = check dbc->execute(`DELETE FROM role_menu WHERE menu_id = ${id}`);
        sql:ExecutionResult result = check dbc->execute(`DELETE FROM menu WHERE id = ${id}`);
        int? affected = result.affectedRowCount;
        deleted = affected is int && affected > 0;
        check commit;
    }
    return deleted;
}
