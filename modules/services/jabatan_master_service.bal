import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Master Data — Jabatan service =====
#
# Read-only master: the contract (`GET /api/v1/master/jabatan`) has no create/update/delete.
# Karyawan is the only other consumer of this module (jabatanExistsActive/findJabatanRefById,
# called directly from karyawan_service — see the FK validation note there).

# Lists jabatan_master rows (flat, unpaginated) with optional search/status filters.
#
# + search - optional ILIKE filter on nama_jabatan
# + status - optional exact status filter (AKTIF / TIDAK_AKTIF); omitted defaults to AKTIF only
# + return - the matching jabatan rows, a VALIDATION_ERROR AppError, or an error
public function getJabatan(string? search, string? status) returns models:JabatanMaster[]|error {
    if status is string && status.trim().length() > 0 && !isValidJabatanStatus(status) {
        return utils:validationError("Status hanya boleh AKTIF atau TIDAK_AKTIF");
    }
    return repositories:findJabatan(search, status);
}

function isValidJabatanStatus(string status) returns boolean {
    return status == "AKTIF" || status == "TIDAK_AKTIF";
}
