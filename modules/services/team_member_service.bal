import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Team Member service =====
#
# Business rules and validation for team_member (assigning karyawan to a proyek per period). Domain
# failures are `models:AppError`; infrastructure failures propagate as plain `error`. Every
# operation first confirms the parent proyek exists (`requireProyek`, reused from unit_share_service
# — same `services` module) so a member can never be created/read/mutated under a missing proyek,
# and the member id is always scoped to that proyek in the repository (cross-proyek access reads as
# NOT_FOUND). Date validation + free-text normalization reuse `validateProyekDate` /
# `normalizeProyekText` from proyek_service. Invitation-email state is backend-controlled and never
# taken from the payload.

const decimal TEAM_MEMBER_BOBOT_MAX = 100;

# Lists all team members of a proyek.
#
# + proyekId - the parent proyek id
# + return - the team members, a NOT_FOUND AppError if the proyek doesn't exist, or an error
public function getTeamMember(int proyekId) returns models:TeamMember[]|error {
    _ = check requireProyek(proyekId);
    return repositories:findTeamMemberByProyek(proyekId);
}

# Creates a team member under a proyek: validates the karyawan/role references, the date period, the
# optional weight, and that the same karyawan isn't already assigned with the same start date.
#
# + proyekId - the parent proyek id
# + payload - the create request body
# + subject - the caller's `sub` claim, stored as created_by
# + return - the created member, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function createTeamMember(int proyekId, models:TeamMemberCreateRequest payload, string subject)
        returns models:TeamMember|error {
    _ = check requireProyek(proyekId);

    string? tglMulai = check validateProyekDate(payload?.tglMulai, "Tanggal mulai");
    string? tglSelesai = check validateProyekDate(payload?.tglSelesai, "Tanggal selesai");
    check validatePeriode(tglMulai, tglSelesai);
    check validateBobot(payload?.bobot);
    string? keterangan = normalizeProyekText(payload?.keterangan);

    check ensureKaryawanExists(payload.karyawanId);
    check ensureProjectRoleExists(payload.roleId);

    boolean dup = check repositories:teamMemberPeriodeExists(proyekId, payload.karyawanId, tglMulai, 0);
    if dup {
        return utils:conflictError("Karyawan sudah ditugaskan pada proyek ini untuk tanggal mulai yang sama");
    }

    return repositories:insertTeamMember(proyekId, payload.karyawanId, payload.roleId, tglMulai, tglSelesai,
            payload?.bobot, keterangan, subject);
}

# Updates a team member. Same validations as create; the member being updated is excluded from the
# duplicate-period check.
#
# + proyekId - the parent proyek id
# + id - the member id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated member, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateTeamMember(int proyekId, int id, models:TeamMemberUpdateRequest payload, string subject)
        returns models:TeamMember|error {
    _ = check requireProyek(proyekId);

    string? tglMulai = check validateProyekDate(payload?.tglMulai, "Tanggal mulai");
    string? tglSelesai = check validateProyekDate(payload?.tglSelesai, "Tanggal selesai");
    check validatePeriode(tglMulai, tglSelesai);
    check validateBobot(payload?.bobot);
    string? keterangan = normalizeProyekText(payload?.keterangan);

    models:TeamMember? existing = check repositories:findTeamMemberById(id, proyekId);
    if existing is () {
        return utils:notFoundError("Team member dengan id " + id.toString() + " tidak ditemukan");
    }

    check ensureKaryawanExists(payload.karyawanId);
    check ensureProjectRoleExists(payload.roleId);

    boolean dup = check repositories:teamMemberPeriodeExists(proyekId, payload.karyawanId, tglMulai, id);
    if dup {
        return utils:conflictError("Karyawan sudah ditugaskan pada proyek ini untuk tanggal mulai yang sama");
    }

    models:TeamMember? updated = check repositories:updateTeamMember(id, proyekId, payload.karyawanId,
            payload.roleId, tglMulai, tglSelesai, payload?.bobot, keterangan, subject);
    if updated is () {
        return utils:notFoundError("Team member dengan id " + id.toString() + " tidak ditemukan");
    }
    return updated;
}

# Soft-deletes a team member.
#
# + proyekId - the parent proyek id
# + id - the member id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deleteTeamMember(int proyekId, int id, string subject) returns error? {
    _ = check requireProyek(proyekId);
    boolean deleted = check repositories:softDeleteTeamMember(id, proyekId, subject);
    if !deleted {
        return utils:notFoundError("Team member dengan id " + id.toString() + " tidak ditemukan");
    }
    return ();
}

# Validates the assignment period: when both dates are given, tgl_selesai may not precede tgl_mulai
# (mirrors the DB's `ck_team_member_periode`). Both are already-validated YYYY-MM-DD strings, so a
# lexicographic comparison is a correct chronological comparison.
#
# + tglMulai - the optional start date
# + tglSelesai - the optional end date
# + return - a VALIDATION_ERROR AppError if the period is inverted, else ()
function validatePeriode(string? tglMulai, string? tglSelesai) returns models:AppError? {
    if tglMulai is string && tglSelesai is string && tglSelesai < tglMulai {
        return utils:validationError("Tanggal selesai tidak boleh sebelum tanggal mulai");
    }
    return ();
}

# Validates the optional bobot (effort weight): 0..100 when present.
#
# + bobot - the optional effort weight
# + return - a VALIDATION_ERROR AppError if out of range, else ()
function validateBobot(decimal? bobot) returns models:AppError? {
    if bobot is decimal && (bobot < 0d || bobot > TEAM_MEMBER_BOBOT_MAX) {
        return utils:validationError("Bobot harus di antara 0 dan 100");
    }
    return ();
}

# Fails with VALIDATION_ERROR if the referenced karyawan doesn't exist (or is inactive).
#
# + karyawanId - the karyawan id to check
# + return - a VALIDATION_ERROR AppError if missing, () if ok, or an error
function ensureKaryawanExists(int karyawanId) returns models:AppError|error? {
    boolean ok = check repositories:karyawanExistsActive(karyawanId);
    if !ok {
        return utils:validationError("Karyawan tidak ditemukan");
    }
    return ();
}

# Fails with VALIDATION_ERROR if the referenced project role doesn't exist (or is inactive).
#
# + roleId - the project_role_master id to check
# + return - a VALIDATION_ERROR AppError if missing, () if ok, or an error
function ensureProjectRoleExists(int roleId) returns models:AppError|error? {
    boolean ok = check repositories:projectRoleExistsActive(roleId);
    if !ok {
        return utils:validationError("Project role tidak ditemukan");
    }
    return ();
}
