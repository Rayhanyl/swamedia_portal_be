import rayha/swamedia_portal_be.config;
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
# taken from the payload — it's only ever written by `sendTeamMemberUndangan` below, the actual
# email-sending flow (via `repositories:sendEmail`, `sys_config`-gated).

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
public function createTeamMember(int proyekId, models:TeamMemberCreateRequest payload, string subject, string? ipAddress = ())
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

    models:TeamMember created = check repositories:insertTeamMember(proyekId, payload.karyawanId, payload.roleId,
            tglMulai, tglSelesai, payload?.bobot, keterangan, subject);
    logAudit("team_member", created.id.toString(), "CREATE", (), created.toJson(), subject, ipAddress);
    return created;
}

# Updates a team member. Same validations as create; the member being updated is excluded from the
# duplicate-period check.
#
# + proyekId - the parent proyek id
# + id - the member id to update
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated member, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateTeamMember(int proyekId, int id, models:TeamMemberUpdateRequest payload, string subject, string? ipAddress = ())
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
    logAudit("team_member", id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Soft-deletes a team member.
#
# + proyekId - the parent proyek id
# + id - the member id to delete
# + subject - the caller's `sub` claim, stored as updated_by
# + return - (), a NOT_FOUND AppError, or an error
public function deleteTeamMember(int proyekId, int id, string subject, string? ipAddress = ()) returns error? {
    _ = check requireProyek(proyekId);
    // Read the row before deleting purely so the audit entry can record what was removed.
    models:TeamMember? existing = check repositories:findTeamMemberById(id, proyekId);
    boolean deleted = check repositories:softDeleteTeamMember(id, proyekId, subject);
    if !deleted {
        return utils:notFoundError("Team member dengan id " + id.toString() + " tidak ditemukan");
    }
    logAudit("team_member", id.toString(), "DELETE", existing is () ? () : existing.toJson(), (), subject, ipAddress);
    return ();
}

# Sends the "undangan" (invitation) email to every team member of a proyek whose undangan_status is
# BELUM_DIKIRIM or GAGAL — members already TERKIRIM are skipped, so re-clicking "Kirim Email
# Undangan Project" after adding one more member only emails the new one. Gated by the
# `sys_config.notif_team_member_aktif` switch (admin-editable at runtime, no redeploy needed). The
# sender address comes from `sys_config.notif_email_pengirim`, falling back to
# `config:smtpFromAddressFallback` if that setting is unset.
#
# Each member is independent: a send failure (missing email, SMTP error, ...) is recorded as GAGAL
# on that member and does not stop the rest. A `notification` row (visible in the karyawan's own
# in-app inbox) plus a `notification_email_log` delivery record are written per member either way.
# Infra failures (DB errors) still propagate via `check` and abort the whole call — only the actual
# email send is treated as an expected, per-member failure mode.
#
# + proyekId - the parent proyek id
# + subject - the caller's `sub` claim, stored as undangan_sent_by
# + ipAddress - the caller's IP, for the audit log entry
# + return - a summary of what was attempted, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function sendTeamMemberUndangan(int proyekId, string subject, string? ipAddress = ())
        returns models:TeamMemberUndanganResult|error {
    models:Proyek proyek = check requireProyek(proyekId);

    models:SysConfig? aktifConfig = check repositories:findSysConfigByKey("notif_team_member_aktif");
    if aktifConfig is models:SysConfig && aktifConfig.value == "false" {
        return utils:validationError(
                "Notifikasi email tim proyek sedang dinonaktifkan (lihat Pengaturan Sistem)");
    }

    models:SysConfig? fromConfig = check repositories:findSysConfigByKey("notif_email_pengirim");
    string? fromConfigured = fromConfig is models:SysConfig ? fromConfig.value : ();
    string fromAddress = fromConfigured is string && fromConfigured.trim().length() > 0
        ? fromConfigured : config:smtpFromAddressFallback;

    models:TeamMemberUndanganTarget[] targets = check repositories:findTeamMemberPendingUndangan(proyekId);

    models:TeamMemberUndanganItem[] items = [];
    int sentCount = 0;
    int failedCount = 0;

    foreach models:TeamMemberUndanganTarget target in targets {
        string pesan = buildUndanganMessage(proyek, target.roleNama);
        int notificationId = check repositories:insertNotification(target.karyawanId, "PENUGASAN",
                "Penugasan Tim Proyek " + proyek.kodeProyek, pesan, "proyek", proyekId, "Lihat Proyek");

        string? email = target.karyawanEmail;
        if email is () || email.trim().length() == 0 {
            check repositories:markUndanganStatus(target.id, proyekId, "GAGAL", subject);
            check repositories:insertNotificationEmailLog(notificationId, "-", "FAILED",
                    "Karyawan tidak memiliki alamat email", false);
            items.push({
                id: target.id,
                karyawanNama: target.karyawanNama,
                status: "GAGAL",
                errorMessage: "Karyawan tidak memiliki alamat email"
            });
            failedCount += 1;
            continue;
        }

        error? sendResult = repositories:sendEmail(email, fromAddress,
                "Undangan Bergabung Proyek " + proyek.kodeProyek, pesan);
        if sendResult is error {
            check repositories:markUndanganStatus(target.id, proyekId, "GAGAL", subject);
            check repositories:insertNotificationEmailLog(notificationId, email, "FAILED",
                    sendResult.message(), false);
            items.push({id: target.id, karyawanNama: target.karyawanNama, status: "GAGAL",
                errorMessage: sendResult.message()});
            failedCount += 1;
        } else {
            check repositories:markUndanganStatus(target.id, proyekId, "TERKIRIM", subject);
            check repositories:insertNotificationEmailLog(notificationId, email, "SENT", (), true);
            items.push({id: target.id, karyawanNama: target.karyawanNama, status: "TERKIRIM", errorMessage: ()});
            sentCount += 1;
        }
    }

    if targets.length() > 0 {
        logAudit("team_member", proyekId.toString(), "UPDATE", (),
                {totalTargeted: targets.length(), totalSent: sentCount, totalFailed: failedCount}.toJson(),
                subject, ipAddress);
    }

    return {totalTargeted: targets.length(), totalSent: sentCount, totalFailed: failedCount, items: items};
}

# Builds the invitation email/notification body for one team member assignment.
#
# + proyek - the proyek the member is assigned to
# + roleNama - the member's project role name
# + return - the Indonesian-language message body
function buildUndanganMessage(models:Proyek proyek, string roleNama) returns string {
    return "Anda ditugaskan sebagai " + roleNama + " pada proyek " + proyek.kodeProyek + " - " +
        proyek.namaProyek + " (Customer: " + proyek.customerNama + ", PIC Sales: " + proyek.picSalesNama +
        "). Silakan login ke Swamedia Portal untuk detail lebih lanjut.";
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
