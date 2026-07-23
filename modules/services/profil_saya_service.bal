import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Profil Saya (self-service profile) service =====
#
# Resolves the caller's own karyawan record via the `subject_id` linked to their WSO2 IS identity
# (the `sub` claim of their access token) and lets them view/update their own contact info. Only
# `email`/`noHp` are self-editable — nik/nama/jabatan/unit/status/subjectId stay HR-managed via the
# Karyawan master module (`karyawan_service`). Reuses `EMAIL_PATTERN`/`validateNoHp`/`trimToNil` from
# `karyawan_service` (same `services` module) so the two modules can never validate contact info
# differently.

# Fetches the caller's own karyawan profile.
#
# + subject - the caller's `sub` claim
# + return - the caller's karyawan detail, a NOT_FOUND AppError if no karyawan is linked, or an error
public function getMyProfile(string subject) returns models:KaryawanDetail|error {
    return requireKaryawanBySubject(subject);
}

# Updates the caller's own contact info (email, noHp only).
#
# + subject - the caller's `sub` claim
# + payload - the update request body
# + return - the updated profile, a VALIDATION_ERROR/NOT_FOUND/CONFLICT AppError, or an error
public function updateMyProfile(string subject, models:ProfilSayaUpdateRequest payload, string? ipAddress = ())
        returns models:KaryawanDetail|error {
    models:KaryawanDetail existing = check requireKaryawanBySubject(subject);

    string email = payload.email.trim().toLowerAscii();
    if email.length() == 0 {
        return utils:validationError("Email wajib diisi");
    }
    if !EMAIL_PATTERN.isFullMatch(email) {
        return utils:validationError("Format email tidak valid");
    }
    string? noHp = trimToNil(payload?.noHp);
    check validateNoHp(noHp);

    if check repositories:emailExists(email, existing.id) {
        return utils:conflictError("Email sudah digunakan");
    }

    int? updatedId = check repositories:updateKaryawanContact(existing.id, email, noHp, subject);
    if updatedId is () {
        return utils:notFoundError("Profil karyawan tidak ditemukan");
    }

    models:KaryawanDetail? updated = check repositories:findKaryawanById(existing.id);
    if updated is () {
        return utils:notFoundError("Profil karyawan tidak ditemukan");
    }
    // Audited against `karyawan` (the table actually written), not a separate "profil_saya" name —
    // this is the self-service door onto the same row the Karyawan master module edits.
    logAudit("karyawan", existing.id.toString(), "UPDATE", existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}

# Resolves the caller's karyawan record via subject_id. Shared by `profil_saya_service` and
# `notifikasi_service` (same module) — every "my ..." endpoint needs this same lookup.
#
# + subject - the caller's `sub` claim
# + return - the caller's karyawan detail, a NOT_FOUND AppError if no karyawan is linked, or an error
function requireKaryawanBySubject(string subject) returns models:KaryawanDetail|error {
    models:KaryawanDetail? karyawan = check repositories:findKaryawanBySubjectId(subject);
    if karyawan is () {
        return utils:notFoundError("Akun Anda belum tertaut ke data karyawan, hubungi admin");
    }
    return karyawan;
}
