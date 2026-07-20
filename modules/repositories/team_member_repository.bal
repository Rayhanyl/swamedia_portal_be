import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Team Member repository =====
#
# All access to the `team_member` table (karyawan assigned to a proyek in a project role for a
# period). Parameterized `sql:ParameterizedQuery` templates only. Reads JOIN `karyawan` and
# `project_role_master` to resolve display names in a single query (no N+1). Every read/mutation is
# scoped to a proyek_id so a member id from one proyek can never be operated on through another's
# path. Invitation-email columns (`undangan_status`/`undangan_sent_at`/`undangan_sent_by`) are
# backend-controlled and never written from CRUD payloads — `undangan_status` defaults to
# 'BELUM_DIKIRIM' at the DB level.

# Lists all non-deleted team members of a proyek (with joined karyawan + role names), oldest first.
#
# + proyekId - the owning proyek id
# + return - the team members, or an error
public function findTeamMemberByProyek(int proyekId) returns models:TeamMember[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:TeamMember m in dbc->query(`
            SELECT tm.id, tm.proyek_id AS "proyekId", tm.karyawan_id AS "karyawanId", k.nama AS "karyawanNama",
                   tm.role_id AS "roleId", pr.nama_role AS "roleNama",
                   tm.tgl_mulai::text AS "tglMulai", tm.tgl_selesai::text AS "tglSelesai",
                   tm.bobot, tm.keterangan, tm.undangan_status AS "undanganStatus",
                   tm.undangan_sent_at::text AS "undanganSentAt", tm.undangan_sent_by AS "undanganSentBy",
                   tm.created_at::text AS "createdAt", tm.updated_at::text AS "updatedAt",
                   tm.created_by AS "createdBy", tm.updated_by AS "updatedBy"
            FROM team_member tm
            JOIN karyawan k ON k.id = tm.karyawan_id
            JOIN project_role_master pr ON pr.id = tm.role_id
            WHERE tm.proyek_id = ${proyekId} AND tm.is_deleted = false
            ORDER BY tm.id ASC`, models:TeamMember)
        select m;
}

# Fetches a single non-deleted team member by id AND owning proyek (with joined names + audit).
#
# + id - the team_member id
# + proyekId - the proyek the member must belong to
# + return - the member, `()` if not found (wrong proyek, missing, or deleted), or an error
public function findTeamMemberById(int id, int proyekId) returns models:TeamMember?|error {
    postgresql:Client dbc = check dbClient();
    models:TeamMember|sql:Error result = dbc->queryRow(`
        SELECT tm.id, tm.proyek_id AS "proyekId", tm.karyawan_id AS "karyawanId", k.nama AS "karyawanNama",
               tm.role_id AS "roleId", pr.nama_role AS "roleNama",
               tm.tgl_mulai::text AS "tglMulai", tm.tgl_selesai::text AS "tglSelesai",
               tm.bobot, tm.keterangan, tm.undangan_status AS "undanganStatus",
               tm.undangan_sent_at::text AS "undanganSentAt", tm.undangan_sent_by AS "undanganSentBy",
               tm.created_at::text AS "createdAt", tm.updated_at::text AS "updatedAt",
               tm.created_by AS "createdBy", tm.updated_by AS "updatedBy"
        FROM team_member tm
        JOIN karyawan k ON k.id = tm.karyawan_id
        JOIN project_role_master pr ON pr.id = tm.role_id
        WHERE tm.id = ${id} AND tm.proyek_id = ${proyekId} AND tm.is_deleted = false`, models:TeamMember);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Returns whether another non-deleted assignment already exists for the same
# (proyek, karyawan, tgl_mulai) — mirrors the `uq_team_member_proyek_karyawan_periode` constraint as
# a friendly pre-check. Handles the NULL `tgl_mulai` case explicitly (Postgres treats NULLs as
# distinct in a UNIQUE index, so a friendly duplicate check must special-case it). `excludeId` skips
# a row (0 on insert; target id on update).
#
# + proyekId - the proyek id
# + karyawanId - the karyawan id
# + tglMulai - the assignment start date, or () for an open start
# + excludeId - a team_member id to exclude (0 = none)
# + return - true if a conflicting assignment exists, or an error
public function teamMemberPeriodeExists(int proyekId, int karyawanId, string? tglMulai, int excludeId)
        returns boolean|error {
    postgresql:Client dbc = check dbClient();
    if tglMulai is string {
        int count = check dbc->queryRow(`
            SELECT count(*) FROM team_member
            WHERE proyek_id = ${proyekId} AND karyawan_id = ${karyawanId} AND tgl_mulai = ${tglMulai}::date
                  AND is_deleted = false AND id <> ${excludeId}`);
        return count > 0;
    }
    int count = check dbc->queryRow(`
        SELECT count(*) FROM team_member
        WHERE proyek_id = ${proyekId} AND karyawan_id = ${karyawanId} AND tgl_mulai IS NULL
              AND is_deleted = false AND id <> ${excludeId}`);
    return count > 0;
}

# Returns whether an active (non-deleted) project role with the given id exists.
# NOTE: `project_role_master` has no dedicated CRUD module yet, so this queries the table directly
# (same precedent as the kontrak helpers in proyek_repository). The table has no `is_deleted`
# column — rows are toggled via `status` — so "active" here means `status = 'AKTIF'`.
# TODO(project-role-master-module): move into its own repository if that master module is built.
#
# + id - the project_role_master id to check
# + return - true if an active project role with that id exists, or an error
public function projectRoleExistsActive(int id) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    int count = check dbc->queryRow(
        `SELECT count(*) FROM project_role_master WHERE id = ${id} AND status = 'AKTIF'`);
    return count > 0;
}

# Inserts a new team member (undangan_status defaults to 'BELUM_DIKIRIM') and returns the created
# row (joined + audit).
#
# + proyekId - the owning proyek id
# + karyawanId - the assigned karyawan
# + roleId - the project role
# + tglMulai - optional start date (YYYY-MM-DD)
# + tglSelesai - optional end date (YYYY-MM-DD)
# + bobot - optional effort weight
# + keterangan - optional free-text note
# + createdBy - the `sub` claim of the caller
# + return - the created team member, or an error
public function insertTeamMember(int proyekId, int karyawanId, int roleId, string? tglMulai,
        string? tglSelesai, decimal? bobot, string? keterangan, string createdBy)
        returns models:TeamMember|error {
    postgresql:Client dbc = check dbClient();
    int newId = check dbc->queryRow(`
        INSERT INTO team_member (proyek_id, karyawan_id, role_id, tgl_mulai, tgl_selesai, bobot,
                keterangan, created_by)
        VALUES (${proyekId}, ${karyawanId}, ${roleId}, ${tglMulai}::date, ${tglSelesai}::date, ${bobot},
                ${keterangan}, ${createdBy})
        RETURNING id`);
    models:TeamMember? created = check findTeamMemberById(newId, proyekId);
    if created is () {
        return error("Team member yang baru dibuat tidak dapat dibaca kembali");
    }
    return created;
}

# Updates a non-deleted team member (scoped to its proyek) and returns the updated row. Never
# touches the invitation-email columns.
#
# + id - the team_member id
# + proyekId - the proyek the member must belong to
# + karyawanId - new karyawan id
# + roleId - new project role id
# + tglMulai - new start date, or () to clear it
# + tglSelesai - new end date, or () to clear it
# + bobot - new effort weight, or () to clear it
# + keterangan - new free-text note, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - the updated member, `()` if it does not exist (wrong proyek/deleted), or an error
public function updateTeamMember(int id, int proyekId, int karyawanId, int roleId, string? tglMulai,
        string? tglSelesai, decimal? bobot, string? keterangan, string updatedBy)
        returns models:TeamMember?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE team_member SET karyawan_id = ${karyawanId}, role_id = ${roleId},
               tgl_mulai = ${tglMulai}::date, tgl_selesai = ${tglSelesai}::date, bobot = ${bobot},
               keterangan = ${keterangan}, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND proyek_id = ${proyekId} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findTeamMemberById(id, proyekId);
}

# Soft-deletes a team member (sets is_deleted = true). Never physically deletes.
#
# + id - the team_member id
# + proyekId - the proyek the member must belong to
# + updatedBy - the `sub` claim of the caller
# + return - true if a row was updated, false if it did not exist (wrong proyek/deleted), or an error
public function softDeleteTeamMember(int id, int proyekId, string updatedBy) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE team_member SET is_deleted = true, updated_by = ${updatedBy}, updated_at = now()
        WHERE id = ${id} AND proyek_id = ${proyekId} AND is_deleted = false`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}
