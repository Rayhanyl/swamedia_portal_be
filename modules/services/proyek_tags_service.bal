import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Sales Unit — Proyek Tags service =====
#
# Business rules for the proyek <-> tags many-to-many. Domain failures are `models:AppError`;
# infrastructure failures propagate as plain `error`. Every operation first confirms the parent
# proyek exists (`requireProyek`, reused from unit_share_service — same `services` module). The
# junction has no audit columns, so these operations record no created_by/updated_by; the
# service-level JWT guard still protects them.

# Lists the tags attached to a proyek.
#
# + proyekId - the parent proyek id
# + return - the attached tags, a NOT_FOUND AppError if the proyek doesn't exist, or an error
public function getProyekTags(int proyekId) returns models:ProyekTag[]|error {
    _ = check requireProyek(proyekId);
    return repositories:findTagsByProyek(proyekId);
}

# Replaces a proyek's entire tag set. De-duplicates the incoming ids, verifies every one references
# an existing non-deleted tag, then swaps the set atomically. Returns the resulting attached tags.
#
# + proyekId - the parent proyek id
# + payload - the desired complete set of tag ids
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - the resulting attached tags, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function replaceProyekTags(int proyekId, models:ProyekTagsUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:ProyekTag[]|error {
    _ = check requireProyek(proyekId);

    int[] uniqueIds = check validateAndDedupTagIds(payload.tagIds);
    models:ProyekTag[] before = check repositories:findTagsByProyek(proyekId);
    check repositories:replaceProyekTags(proyekId, uniqueIds);
    models:ProyekTag[] after = check repositories:findTagsByProyek(proyekId);
    logAudit("proyek_tags", proyekId.toString(), "UPDATE", before.toJson(), after.toJson(), subject, ipAddress);
    return after;
}

# Attaches a single tag to a proyek (idempotent — attaching an already-attached tag is a no-op).
# Returns the resulting attached tags.
#
# + proyekId - the parent proyek id
# + tagsId - the tag id to attach
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - the resulting attached tags, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function attachProyekTag(int proyekId, int tagsId, string subject, string? ipAddress = ()) returns models:ProyekTag[]|error {
    _ = check requireProyek(proyekId);
    check ensureTagExists(tagsId);
    check repositories:attachProyekTag(proyekId, tagsId);
    logAudit("proyek_tags", proyekId.toString(), "CREATE", (), {"tagsId": tagsId}, subject, ipAddress);
    return repositories:findTagsByProyek(proyekId);
}

# Detaches a single tag from a proyek.
#
# + proyekId - the parent proyek id
# + tagsId - the tag id to detach
# + subject - the caller's `sub` claim, stored as the audit_log `aktor`
# + return - (), a NOT_FOUND AppError if the tag wasn't attached (or the proyek is missing), or an error
public function detachProyekTag(int proyekId, int tagsId, string subject, string? ipAddress = ()) returns error? {
    _ = check requireProyek(proyekId);
    boolean detached = check repositories:detachProyekTag(proyekId, tagsId);
    if !detached {
        return utils:notFoundError("Tag dengan id " + tagsId.toString() + " tidak terpasang pada proyek ini");
    }
    logAudit("proyek_tags", proyekId.toString(), "DELETE", {"tagsId": tagsId}, (), subject, ipAddress);
    return ();
}

# De-duplicates the requested tag ids (preserving first-seen order) and verifies each references an
# existing non-deleted tag, failing with VALIDATION_ERROR on the first unknown id.
#
# + tagIds - the requested tag ids (may contain duplicates)
# + return - the de-duplicated, validated ids, a VALIDATION_ERROR AppError, or an error
function validateAndDedupTagIds(int[] tagIds) returns int[]|error {
    int[] uniqueIds = [];
    foreach int tagsId in tagIds {
        if uniqueIds.indexOf(tagsId) is int {
            continue;
        }
        models:Tags? tag = check repositories:findTagsById(tagsId);
        if tag is () {
            return utils:validationError("Tag dengan id " + tagsId.toString() + " tidak ditemukan");
        }
        uniqueIds.push(tagsId);
    }
    return uniqueIds;
}

# Fails with VALIDATION_ERROR if the referenced tag doesn't exist (or is deleted).
#
# + tagsId - the tag id to check
# + return - a VALIDATION_ERROR AppError if missing, () if ok, or an error
function ensureTagExists(int tagsId) returns models:AppError|error? {
    models:Tags? tag = check repositories:findTagsById(tagsId);
    if tag is () {
        return utils:validationError("Tag dengan id " + tagsId.toString() + " tidak ditemukan");
    }
    return ();
}
