import ballerina/lang.regexp;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Unit service =====
#
# Business rules and validation for units. Domain failures are returned as `models:AppError`
# (carrying the HTTP status + error code); infrastructure failures propagate as plain
# `error`. The resource layer distinguishes the two in its `on fail` block.

const string STATUS_AKTIF = "AKTIF";
const string STATUS_TIDAK_AKTIF = "TIDAK_AKTIF";

# kode_nik: exactly 2 uppercase letters (the DB column is VARCHAR(2)).
final regexp:RegExp KODE_NIK_PATTERN = re `[A-Z]{2}`;

# Maximum ancestor-chain depth walked when checking for circular references — a safety
# valve against already-corrupt data, far above any realistic org hierarchy depth.
const int MAX_TREE_DEPTH = 10000;

# Lists non-deleted units with optional filters and pagination.
#
# + search - optional ILIKE filter on nama_unit
# + status - optional status filter (AKTIF / TIDAK_AKTIF)
# + parentId - optional filter selecting only children of this unit id
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page of units plus pagination metadata, or an error
public function getUnits(string? search, string? status, int? parentId, int page, int 'limit)
        returns models:UnitListResult|error {
    if status is string && status.trim().length() > 0 && !isValidStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:Unit[] items; int totalItems;|} result =
        check repositories:findUnits(search, status, parentId, safeLimit, offset);

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

# Fetches a single unit by id.
#
# + id - the unit id
# + return - the unit, or a NOT_FOUND AppError if it does not exist, or an error
public function getUnitById(int id) returns models:Unit|error {
    models:Unit? unit = check repositories:findUnitById(id);
    if unit is () {
        return utils:notFoundError("Unit dengan id " + id.toString() + " tidak ditemukan");
    }
    return unit;
}

# Builds the full unit hierarchy from a single flat read: index every active unit by id,
# then attach each node to its parent's `children` (roots are nodes whose parent is absent
# among the active units). No recursive SQL — the tree is assembled in memory.
#
# + return - the root nodes of the unit tree, or an error
public function getUnitTree() returns models:UnitTreeNode[]|error {
    models:Unit[] units = check repositories:findAllActiveUnits();

    map<models:UnitTreeNode> nodeById = {};
    foreach models:Unit u in units {
        nodeById[u.id.toString()] = {
            id: u.id,
            namaUnit: u.namaUnit,
            kodeUnit: u.kodeUnit,
            parentUnitId: u.parentUnitId,
            tipeUnit: u.tipeUnit,
            status: u.status,
            children: []
        };
    }

    models:UnitTreeNode[] roots = [];
    foreach models:Unit u in units {
        models:UnitTreeNode node = nodeById.get(u.id.toString());
        int? parentId = u.parentUnitId;
        if parentId is int && nodeById.hasKey(parentId.toString()) {
            models:UnitTreeNode parent = nodeById.get(parentId.toString());
            parent.children.push(node);
        } else {
            roots.push(node);
        }
    }
    return roots;
}

# Creates a new unit after validating name, status and (if supplied) the parent reference.
#
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created unit, a VALIDATION_ERROR AppError, or an error
public function createUnit(models:UnitCreateRequest payload, string subject, string? ipAddress = ()) returns models:Unit|error {
    string namaUnit = payload.namaUnit.trim();
    check validateNamaUnit(namaUnit);

    string kodeUnit = payload.kodeUnit.trim();
    check validateKodeUnit(kodeUnit);

    string kodeNik = payload.kodeNik.trim().toUpperAscii();
    check validateKodeNik(kodeNik);

    string status = payload?.status ?: STATUS_AKTIF;
    if !isValidStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    int? parentUnitId = payload?.parentUnitId;
    if parentUnitId is int {
        boolean exists = check repositories:unitExistsActive(parentUnitId);
        if !exists {
            return utils:validationError("Unit induk tidak ditemukan");
        }
    }

    boolean duplicate = check repositories:namaUnitExists(namaUnit, 0);
    if duplicate {
        return utils:conflictError("Nama unit sudah digunakan");
    }

    boolean kodeDuplicate = check repositories:kodeUnitExists(kodeUnit, 0);
    if kodeDuplicate {
        return utils:conflictError("Kode unit sudah digunakan");
    }

    boolean kodeNikDuplicate = check repositories:kodeNikExists(kodeNik, 0);
    if kodeNikDuplicate {
        return utils:conflictError("Kode NIK sudah digunakan unit lain");
    }

    models:Unit created = check repositories:insertUnit(namaUnit, kodeUnit, kodeNik, parentUnitId, status, subject);
    logAudit("unit", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates an existing unit. Validates name/status, the parent reference, and guards against
# circular references before writing.
#
# + id - the unit id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated unit, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updateUnit(int id, models:UnitUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:Unit|error {
    string namaUnit = payload.namaUnit.trim();
    check validateNamaUnit(namaUnit);

    string kodeUnit = payload.kodeUnit.trim();
    check validateKodeUnit(kodeUnit);

    string kodeNik = payload.kodeNik.trim().toUpperAscii();
    check validateKodeNik(kodeNik);

    if !isValidStatus(payload.status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }

    models:Unit? existing = check repositories:findUnitById(id);
    if existing is () {
        return utils:notFoundError("Unit dengan id " + id.toString() + " tidak ditemukan");
    }

    int? parentUnitId = payload?.parentUnitId;
    if parentUnitId is int {
        boolean exists = check repositories:unitExistsActive(parentUnitId);
        if !exists {
            return utils:validationError("Unit induk tidak ditemukan");
        }
        boolean circular = check wouldCreateCircularReference(id, parentUnitId);
        if circular {
            return utils:validationError("Parent unit tidak boleh membentuk referensi melingkar");
        }
    }

    boolean duplicate = check repositories:namaUnitExists(namaUnit, id);
    if duplicate {
        return utils:conflictError("Nama unit sudah digunakan");
    }

    boolean kodeDuplicate = check repositories:kodeUnitExists(kodeUnit, id);
    if kodeDuplicate {
        return utils:conflictError("Kode unit sudah digunakan");
    }

    boolean kodeNikDuplicate = check repositories:kodeNikExists(kodeNik, id);
    if kodeNikDuplicate {
        return utils:conflictError("Kode NIK sudah digunakan unit lain");
    }

    models:Unit? updated =
        check repositories:updateUnit(id, namaUnit, kodeUnit, kodeNik, parentUnitId, payload.status, subject);
    if updated is () {
        return utils:notFoundError("Unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("unit", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Soft-deletes a unit after ensuring it exists and has no active sub-units.
#
# + id - the unit id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND/CONFLICT AppError, or an error
public function deleteUnit(int id, string subject, string? ipAddress = ()) returns error? {
    models:Unit? existing = check repositories:findUnitById(id);
    if existing is () {
        return utils:notFoundError("Unit dengan id " + id.toString() + " tidak ditemukan");
    }

    boolean hasChildren = check repositories:hasActiveChildren(id);
    if hasChildren {
        return utils:conflictError("Unit tidak dapat dihapus karena masih memiliki sub-unit aktif");
    }

    boolean deleted = check repositories:softDeleteUnit(id, subject);
    if !deleted {
        return utils:notFoundError("Unit dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("unit", id.toString(), "DELETE", existing.toJson(), (), subject, ipAddress);
    return ();
}

# Validates nama_unit: required, 3-100 characters (after trimming).
#
# + namaUnit - the unit name to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateNamaUnit(string namaUnit) returns models:AppError? {
    if namaUnit.length() < 3 || namaUnit.length() > 100 {
        return utils:validationError("nama_unit wajib diisi, panjang 3-100 karakter");
    }
    return ();
}

# Validates kode_unit: required, 1-20 characters (after trimming) — matches the DB column's
# VARCHAR(20) NOT NULL UNIQUE constraint.
#
# + kodeUnit - the unit code to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateKodeUnit(string kodeUnit) returns models:AppError? {
    if kodeUnit.length() < 1 || kodeUnit.length() > 20 {
        return utils:validationError("kode_unit wajib diisi, panjang maksimal 20 karakter");
    }
    return ();
}

# Validates kode_nik: required, exactly 2 letters (matches the DB column's VARCHAR(2) NOT
# NULL UNIQUE constraint) — the legacy 2-letter code embedded in karyawan NIK for this unit
# (e.g. "BL"), deliberately independent from `kode_unit` (e.g. "BILL").
#
# + kodeNik - the code to validate
# + return - a VALIDATION_ERROR AppError if invalid, () if valid
function validateKodeNik(string kodeNik) returns models:AppError? {
    if !KODE_NIK_PATTERN.isFullMatch(kodeNik) {
        return utils:validationError("kode_nik wajib diisi, tepat 2 huruf (A-Z)");
    }
    return ();
}

function isValidStatus(string status) returns boolean {
    return status == STATUS_AKTIF || status == STATUS_TIDAK_AKTIF;
}

# Returns whether making `newParentId` the parent of `unitId` would create a cycle —
# i.e. `unitId` is `newParentId` itself or appears among `newParentId`'s ancestors.
# Walks up the parent chain from `newParentId`.
#
# + unitId - the unit being reparented
# + newParentId - the proposed new parent unit id
# + return - true if this would create a circular reference, or an error
function wouldCreateCircularReference(int unitId, int newParentId) returns boolean|error {
    int? current = newParentId;
    int depth = 0;
    while current is int {
        if current == unitId {
            return true;
        }
        models:Unit? ancestor = check repositories:findUnitById(current);
        if ancestor is () {
            break;
        }
        current = ancestor.parentUnitId;
        depth += 1;
        if depth > MAX_TREE_DEPTH {
            return error("Circular reference walk exceeded maximum depth for unit " + unitId.toString());
        }
    }
    return false;
}
