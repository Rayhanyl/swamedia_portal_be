import ballerina/log;
import rayha/swamedia_portal_be.config;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Akun Saya (self-service WSO2 IS identity update) service =====
#
# Lets the caller update their OWN identity in WSO2 Identity Server (password/email/first name/
# last name/phone) — distinct from `profil_saya_service`, which only edits the local karyawan HR
# contact record. Shares `applyAccountUpdate` with `user_cache_service:updateUserAccount` (the
# Super-Admin-credentialed admin equivalent), so both entry points validate and map fields
# identically; the only difference is which subject_id is targeted and whether `roleId` is allowed.
#
# NOTE (verification): like the rest of the SCIM2 write path, this could not be exercised against a
# live WSO2 IS in this environment — see scim2_repository.bal.

# Fetches the caller's own WSO2 IS identity snapshot — used to prefill the Akun Saya edit form with
# current values before the user changes anything. `subject` is always the caller's own `sub` claim.
#
# + subject - the caller's `sub` claim (their own WSO2 IS subject id)
# + return - the current identity snapshot, a NOT_FOUND AppError, or an error
public function getMyAccount(string subject) returns models:AkunProfile|error {
    json? scimResponse = check repositories:scimAdminGet(subject);
    if scimResponse is () {
        return utils:notFoundError("Akun WSO2 IS Anda tidak ditemukan");
    }
    return parseAkunProfile(subject, scimResponse);
}

# Updates the caller's own WSO2 IS identity. `subject` is always the caller's own `sub` claim
# (resolved server-side by the caller — see main.bal) — never accepted from client input — so this
# can only ever reach the caller's own account.
#
# + subject - the caller's `sub` claim (their own WSO2 IS subject id)
# + payload - the update request body
# + return - the updated identity snapshot, a VALIDATION_ERROR AppError, or an error
public function updateMyAccount(string subject, models:AkunSayaUpdateRequest payload)
        returns models:AkunProfile|error {
    // Self-service never sets role/group — see AkunSayaUpdateRequest. Password is changed via the
    // separate updateMyPassword path, not here.
    AccountUpdateInput input = {
        email: payload?.email,
        firstName: payload?.firstName,
        lastName: payload?.lastName,
        telepon: payload?.telepon,
        organization: payload?.organization,
        country: payload?.country
    };
    return applyAccountUpdate(subject, input);
}

# Changes the caller's OWN WSO2 IS password. `subject` is always the caller's own `sub` claim
# (resolved server-side — never client input), so this can only ever reach the caller's own account.
#
# + subject - the caller's `sub` claim (their own WSO2 IS subject id)
# + payload - the new-password request body
# + return - a VALIDATION_ERROR AppError, or an error
public function updateMyPassword(string subject, models:PasswordUpdateRequest payload) returns error? {
    return applyPasswordUpdate(subject, payload.password);
}

# Shared password-change implementation for both the self-service (Akun Saya) and admin (Manajemen
# User) entry points: validates, then issues a lone SCIM2 `replace` of `password` as the Super Admin
# IS account (URL-Doc-IS7 §4). No user_cache write-through — the password is never mirrored locally.
#
# + subjectId - the WSO2 IS subject id whose password to set
# + password - the new password
# + return - a VALIDATION_ERROR AppError, or an error
function applyPasswordUpdate(string subjectId, string password) returns error? {
    if password.length() < 6 {
        return utils:validationError("Password minimal 6 karakter");
    }
    json[] operations = [replaceOp("password", password)];
    _ = check repositories:scimAdminPatch(subjectId, operations);
}

# The SCIM2 enterprise-User extension schema URN (organization lives here).
const string SCIM_ENTERPRISE_SCHEMA = "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User";
# The WSO2-specific SCIM2 schema URN (carries WSO2 claims: emailAddresses, mobileNumbers, country, …).
# NOTE: this is distinct from `config:scimRoleClaimSchema` (the custom-User extension that holds
# `swaportal_role_id`/`swaportal_group_id`) — see the config doc + URL-Doc-IS7.
const string SCIM_WSO2_SCHEMA = "urn:scim:wso2:schema";
# Max length accepted for a mobile number on the SCIM identity path (independent of the Karyawan
# module's own HR phone validation — the two domains are deliberately separate).
const int MOBILE_MAX_LEN = 20;

# Normalized, entry-point-agnostic view of a data (non-password) account update. Both the
# self-service (Akun Saya) and admin (Manajemen User) entry points map their request into this before
# `applyAccountUpdate`. Password is handled separately — see `applyPasswordUpdate`.
#
# + email - optional new email
# + firstName - optional new first name
# + lastName - optional new last name
# + telepon - optional new mobile number ("" clears it)
# + organization - optional organization
# + country - optional country
# + roleId - optional portal role id (admin only)
# + groupId - optional portal group id (admin only)
type AccountUpdateInput record {|
    string? email = ();
    string? firstName = ();
    string? lastName = ();
    string? telepon = ();
    string? organization = ();
    string? country = ();
    int? roleId = ();
    string? groupId = ();
|};

# Shared implementation for both Akun Saya (self-service) and Manajemen User "akun" (admin) WSO2 IS
# identity updates. Validates whichever fields are present, builds the SCIM2 PATCH operations from
# them (one `replace` op per attribute/schema sub-attribute, mirroring URL-Doc-IS7 §3), applies them
# via the Super-Admin-credentialed `repositories:scimAdminPatch`, then best-effort write-throughs
# email/nama into `user_cache` so the read side (Manajemen User list) reflects it immediately.
#
# + subjectId - the WSO2 IS subject id to update
# + input - the normalized set of fields to apply (only non-() fields are sent)
# + return - the updated identity snapshot, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
function applyAccountUpdate(string subjectId, AccountUpdateInput input) returns models:AkunProfile|error {
    json[] operations = [];
    string[] extraSchemas = [];
    boolean usedWso2 = false;
    boolean usedCustom = false;

    string? normalizedEmail = ();
    if input.email is string {
        string trimmedEmail = (<string>input.email).trim().toLowerAscii();
        if trimmedEmail.length() == 0 || !EMAIL_PATTERN.isFullMatch(trimmedEmail) {
            return utils:validationError("Format email tidak valid");
        }
        normalizedEmail = trimmedEmail;
        // Written to BOTH the SCIM standard `emails` and the WSO2 `emailAddresses` claim (URL-Doc-IS7).
        operations.push(replaceOp("emails", <json[]>[trimmedEmail]));
        operations.push(replaceSchemaOp(SCIM_WSO2_SCHEMA, "emailAddresses", <json[]>[trimmedEmail]));
        usedWso2 = true;
    }

    string? normalizedFirstName = ();
    string? normalizedLastName = ();
    if input.firstName is string || input.lastName is string {
        map<json> nameValue = {};
        if input.firstName is string {
            normalizedFirstName = trimToNil(<string>input.firstName);
            if normalizedFirstName is () {
                return utils:validationError("First name tidak boleh kosong");
            }
            nameValue["givenName"] = normalizedFirstName;
        }
        if input.lastName is string {
            normalizedLastName = trimToNil(<string>input.lastName);
            if normalizedLastName is () {
                return utils:validationError("Last name tidak boleh kosong");
            }
            nameValue["familyName"] = normalizedLastName;
        }
        // Partial `name` replace: WSO2 replaces only the sub-attributes present, so sending just
        // givenName leaves familyName untouched (and vice versa) — no `formatted` needed.
        operations.push(replaceOp("name", nameValue));
    }

    if input.telepon is string {
        string telepon = (<string>input.telepon).trim();
        if telepon.length() > MOBILE_MAX_LEN {
            return utils:validationError("Nomor mobile maksimal " + MOBILE_MAX_LEN.toString() + " karakter");
        }
        // "" clears the number (empty arrays); otherwise set both the SCIM `phoneNumbers` and the
        // WSO2 `mobileNumbers` claim (URL-Doc-IS7).
        if telepon.length() == 0 {
            operations.push(replaceOp("phoneNumbers", <json[]>[]));
            operations.push(replaceSchemaOp(SCIM_WSO2_SCHEMA, "mobileNumbers", <json[]>[]));
        } else {
            operations.push(replaceOp("phoneNumbers", <json[]>[{"type": "mobile", "value": telepon}]));
            operations.push(replaceSchemaOp(SCIM_WSO2_SCHEMA, "mobileNumbers", <json[]>[telepon]));
        }
        usedWso2 = true;
    }

    if input.organization is string {
        operations.push(replaceSchemaOp(SCIM_ENTERPRISE_SCHEMA, "organization", (<string>input.organization).trim()));
        extraSchemas.push(SCIM_ENTERPRISE_SCHEMA);
    }

    if input.country is string {
        operations.push(replaceSchemaOp(SCIM_WSO2_SCHEMA, "country", (<string>input.country).trim()));
        usedWso2 = true;
    }

    if input.roleId is int {
        int? validRoleId = check ensureRoleExists(input.roleId);
        if validRoleId is int {
            operations.push(replaceSchemaOp(config:scimRoleClaimSchema, config:scimRoleClaimAttribute,
                    validRoleId.toString()));
            usedCustom = true;
        }
    }

    if input.groupId is string {
        string? groupId = trimToNil(<string>input.groupId);
        if groupId is string {
            operations.push(replaceSchemaOp(config:scimRoleClaimSchema, config:appGroupClaim, groupId));
            usedCustom = true;
        }
    }

    if operations.length() == 0 {
        return utils:validationError("Tidak ada perubahan yang dikirim");
    }
    if usedWso2 {
        extraSchemas.push(SCIM_WSO2_SCHEMA);
    }
    if usedCustom {
        extraSchemas.push(config:scimRoleClaimSchema);
    }

    json scimResponse = check repositories:scimAdminPatch(subjectId, operations, extraSchemas);
    models:AkunProfile profile = parseAkunProfile(subjectId, scimResponse);

    // Best-effort write-through into user_cache (email/nama) — only when those fields could have
    // changed, so a phone-only/password-only/role-only update doesn't needlessly touch the cache.
    if normalizedEmail is string || normalizedFirstName is string || normalizedLastName is string {
        string nama = trimToNil((profile.firstName ?: "") + " " + (profile.lastName ?: "")) ?: "";
        string cacheEmail = profile.email ?: (normalizedEmail ?: "");
        error? cacheErr = repositories:upsertUserCache(subjectId, nama, cacheEmail, ());
        if cacheErr is error {
            log:printError("user_cache write-through failed after SCIM2 akun update", cacheErr);
        }
    }

    return profile;
}

# Builds a single-attribute SCIM2 `replace` operation (`{"op":"replace","value":{key: val}}`). Uses a
# computed key so schema-URN keys (which aren't valid mapping-constructor identifiers) work too.
#
# + key - the attribute (or schema URN) to replace
# + val - the value to set
# + return - the SCIM2 PatchOp operation
function replaceOp(string key, json val) returns json {
    map<json> value = {};
    value[key] = val;
    return {"op": "replace", "value": value};
}

# Builds a SCIM2 `replace` operation for a single sub-attribute nested under a schema URN
# (`{"op":"replace","value":{schemaUrn:{attr: val}}}`) — a partial complex replace that leaves the
# schema block's other sub-attributes untouched.
#
# + schemaUrn - the schema URN the attribute lives under
# + attr - the sub-attribute name
# + val - the value to set
# + return - the SCIM2 PatchOp operation
function replaceSchemaOp(string schemaUrn, string attr, json val) returns json {
    map<json> block = {};
    block[attr] = val;
    return replaceOp(schemaUrn, block);
}

# Builds the AkunProfile snapshot from a raw SCIM2 user resource (as returned by
# `repositories:scimAdminPatch`/`scimAdminGet`). Defensive throughout: any unexpected/missing shape
# just yields () for that field rather than failing the whole (already-successful) update.
#
# + subjectId - the subject id that was patched
# + scimResponse - the raw SCIM2 user resource JSON
# + return - the parsed snapshot
function parseAkunProfile(string subjectId, json scimResponse) returns models:AkunProfile {
    json? nameBlock = scimResponse is map<json> ? scimResponse["name"] : ();
    return {
        subjectId: subjectId,
        email: firstArrayValue(scimResponse, "emails"),
        firstName: nameBlock is map<json> ? jsonString(nameBlock, "givenName") : (),
        lastName: nameBlock is map<json> ? jsonString(nameBlock, "familyName") : (),
        telepon: extractTelepon(scimResponse),
        organization: schemaAttrString(scimResponse, SCIM_ENTERPRISE_SCHEMA, "organization"),
        country: schemaAttrString(scimResponse, SCIM_WSO2_SCHEMA, "country"),
        roleId: extractRoleId(scimResponse),
        groupId: schemaAttrString(scimResponse, config:scimRoleClaimSchema, config:appGroupClaim)
    };
}

# Reads the current mobile number: the SCIM standard `phoneNumbers` first, falling back to the WSO2
# `mobileNumbers` claim.
#
# + scimResponse - the raw SCIM2 user resource JSON
# + return - the mobile number, or () if none present
function extractTelepon(json scimResponse) returns string? {
    string? phone = firstArrayValue(scimResponse, "phoneNumbers");
    if phone is string {
        return phone;
    }
    if scimResponse is map<json> {
        json? wso2 = scimResponse[SCIM_WSO2_SCHEMA];
        if wso2 is map<json> {
            return firstArrayValue(wso2, "mobileNumbers");
        }
    }
    return ();
}

# Reads a string sub-attribute nested under a schema-URN block of a SCIM2 user resource.
#
# + scimResponse - the raw SCIM2 user resource JSON
# + schemaUrn - the schema URN the attribute lives under
# + attr - the sub-attribute name
# + return - the trimmed non-empty string value, or () if absent/blank/unexpected shape
function schemaAttrString(json scimResponse, string schemaUrn, string attr) returns string? {
    if scimResponse is map<json> {
        json? block = scimResponse[schemaUrn];
        if block is map<json> {
            json? v = block[attr];
            if v is string && v.trim().length() > 0 {
                return v;
            }
        }
    }
    return ();
}

# + j - the json value expected to be a mapping
# + key - the key to read
# + return - the string at that key, or () if `j` isn't a mapping or the value isn't a string
function jsonString(json j, string key) returns string? {
    if j is map<json> {
        json? v = j[key];
        if v is string {
            return v;
        }
    }
    return ();
}

# Reads the first meaningful value out of a json array attribute (e.g. SCIM `emails`/`phoneNumbers`).
# WSO2 IS returns these either as arrays of plain strings (`emails: ["a@b.com"]`, as seen in this
# deployment's live payloads) or as arrays of SCIM `{type, value, primary}` objects — this handles
# both.
#
# + j - the json value expected to be a mapping
# + key - the array-valued key to read
# + return - the first element's value, or () if absent/empty/unexpected shape
function firstArrayValue(json j, string key) returns string? {
    if j is map<json> {
        json? arr = j[key];
        if arr is json[] && arr.length() > 0 {
            json first = arr[0];
            if first is string {
                return first;
            }
            return jsonString(first, "value");
        }
    }
    return ();
}

# Reads the `swaportal_role_id` custom attribute back out of a SCIM2 user resource.
#
# + scimResponse - the raw SCIM2 user resource JSON
# + return - the role id, or () if unset/not present/not a valid integer
function extractRoleId(json scimResponse) returns int? {
    if scimResponse is map<json> {
        json? schemaBlock = scimResponse[config:scimRoleClaimSchema];
        if schemaBlock is map<json> {
            json? raw = schemaBlock[config:scimRoleClaimAttribute];
            if raw is string && raw.trim().length() > 0 {
                int|error parsed = int:fromString(raw);
                if parsed is int {
                    return parsed;
                }
            }
        }
    }
    return ();
}
