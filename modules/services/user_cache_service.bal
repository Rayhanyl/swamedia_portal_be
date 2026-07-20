import ballerina/log;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Manajemen User service =====
#
# Reads report over `user_cache` (the local mirror of WSO2 IS users); WRITES go through WSO2's SCIM2
# API (`repositories:scim2*` — schema implementation note #2), never straight into this database.
# After each successful SCIM2 write, a best-effort write-through mirrors the change into `user_cache`
# so the read side reflects it immediately (a failed write-through is logged, not fatal — the
# reconciliation job would reconcile it later). Domain failures are `models:AppError`; infrastructure
# failures propagate as plain `error`.
#
# NOTE: the SCIM2 write path is implemented to spec but could not be verified against a live WSO2 IS
# here — see the doc on scim2_repository.bal.

# Lists user_cache rows with optional filters and pagination.
#
# + search - optional case-insensitive filter on subject_id, nama, or email
# + status - optional exact status filter
# + page - 1-based page number (values < 1 are normalized to 1)
# + limit - page size (values outside 1..100 are normalized to 20)
# + return - the page plus pagination metadata, or an error
public function getUserCache(string? search, string? status, int page, int 'limit)
        returns models:UserCacheListResult|error {
    int safePage = page < 1 ? 1 : page;
    int safeLimit = ('limit < 1 || 'limit > 100) ? 20 : 'limit;
    int offset = (safePage - 1) * safeLimit;

    record {|models:UserCacheItem[] items; int totalItems;|} result =
        check repositories:findUserCache(search, status, safeLimit, offset);

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

# Fetches a single user_cache row by subject_id.
#
# + subjectId - the WSO2 IS subject id
# + return - the row, a NOT_FOUND AppError if it does not exist, or an error
public function getUserCacheBySubjectId(string subjectId) returns models:UserCacheItem|error {
    models:UserCacheItem? item = check repositories:findUserCacheBySubjectId(subjectId);
    if item is () {
        return utils:notFoundError("User dengan subject_id '" + subjectId + "' tidak ditemukan di cache");
    }
    return item;
}

# Provisions a new WSO2 IS user via SCIM2, then write-through mirrors it into user_cache.
#
# + payload - the create request body
# + return - the newly-cached user, a VALIDATION_ERROR AppError, or an error
public function createUser(models:UserCreateRequest payload) returns models:UserCacheItem|error {
    string userName = payload.userName.trim();
    string nama = payload.nama.trim();
    string email = payload.email.trim().toLowerAscii();
    if userName.length() < 1 {
        return utils:validationError("Username wajib diisi");
    }
    if nama.length() < 1 {
        return utils:validationError("Nama wajib diisi");
    }
    if !EMAIL_PATTERN.isFullMatch(email) {
        return utils:validationError("Format email tidak valid");
    }
    if payload.password.length() < 6 {
        return utils:validationError("Password minimal 6 karakter");
    }
    int? roleId = check ensureRoleExists(payload?.roleId);

    string subjectId = check repositories:scimCreateUser(userName, email, nama, payload.password, roleId);

    error? cacheErr = repositories:upsertUserCache(subjectId, nama, email, "ACTIVE");
    if cacheErr is error {
        log:printError("user_cache write-through failed after SCIM2 create", cacheErr);
    }
    return getUserCacheBySubjectId(subjectId);
}

# Updates a user's display name + email via SCIM2, then write-through mirrors it into user_cache.
#
# + subjectId - the WSO2 IS subject id
# + payload - the update request body
# + return - the updated cached user, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updateUser(string subjectId, models:UserUpdateRequest payload) returns models:UserCacheItem|error {
    string nama = payload.nama.trim();
    string email = payload.email.trim().toLowerAscii();
    if nama.length() < 1 {
        return utils:validationError("Nama wajib diisi");
    }
    if !EMAIL_PATTERN.isFullMatch(email) {
        return utils:validationError("Format email tidak valid");
    }

    models:UserCacheItem? existing = check repositories:findUserCacheBySubjectId(subjectId);
    if existing is () {
        return utils:notFoundError("User dengan subject_id '" + subjectId + "' tidak ditemukan");
    }

    check repositories:scimUpdateProfile(subjectId, nama, email);

    error? cacheErr = repositories:upsertUserCache(subjectId, nama, email, ());
    if cacheErr is error {
        log:printError("user_cache write-through failed after SCIM2 update", cacheErr);
    }
    return getUserCacheBySubjectId(subjectId);
}

# Sets (or clears) a user's portal role (`swaportal_role_id`) via SCIM2. No user_cache column mirrors
# the role, so there is no write-through here — the role is read live from userinfo by the middleware.
#
# + subjectId - the WSO2 IS subject id
# + payload - the role update request body
# + return - the cached user, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function setUserRole(string subjectId, models:UserRoleUpdateRequest payload)
        returns models:UserCacheItem|error {
    models:UserCacheItem? existing = check repositories:findUserCacheBySubjectId(subjectId);
    if existing is () {
        return utils:notFoundError("User dengan subject_id '" + subjectId + "' tidak ditemukan");
    }
    int? roleId = check ensureRoleExists(payload.roleId);

    check repositories:scimSetRole(subjectId, roleId);
    return getUserCacheBySubjectId(subjectId);
}

# Enables/disables a user (SCIM `active`) via SCIM2, then write-through mirrors the status into
# user_cache ("ACTIVE" / "DISABLED").
#
# + subjectId - the WSO2 IS subject id
# + payload - the status update request body
# + return - the updated cached user, a NOT_FOUND AppError, or an error
public function setUserStatus(string subjectId, models:UserStatusUpdateRequest payload)
        returns models:UserCacheItem|error {
    models:UserCacheItem? existing = check repositories:findUserCacheBySubjectId(subjectId);
    if existing is () {
        return utils:notFoundError("User dengan subject_id '" + subjectId + "' tidak ditemukan");
    }

    check repositories:scimSetStatus(subjectId, payload.active);

    string status = payload.active ? "ACTIVE" : "DISABLED";
    error? cacheErr = repositories:updateUserCacheStatus(subjectId, status);
    if cacheErr is error {
        log:printError("user_cache write-through failed after SCIM2 status change", cacheErr);
    }
    return getUserCacheBySubjectId(subjectId);
}

# Super Admin update of ANOTHER user's full WSO2 IS identity (password reset, email, first/last
# name, phone, portal role) in one call — the admin counterpart of
# `akun_saya_service:updateMyAccount`, sharing its validation/mapping via `applyAccountUpdate`. Runs
# as the Super Admin IS account (config:scimAdminUsername/scimAdminPassword), not the app-level
# credential the other Manajemen User writes above use.
#
# + subjectId - the WSO2 IS subject id to update (the TARGET user, not the caller)
# + payload - the update request body
# + return - the updated identity snapshot, a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updateUserAccount(string subjectId, models:UserAccountUpdateRequest payload)
        returns models:AkunProfile|error {
    models:UserCacheItem? existing = check repositories:findUserCacheBySubjectId(subjectId);
    if existing is () {
        return utils:notFoundError("User dengan subject_id '" + subjectId + "' tidak ditemukan");
    }
    AccountUpdateInput input = {
        email: payload?.email,
        firstName: payload?.firstName,
        lastName: payload?.lastName,
        telepon: payload?.telepon,
        organization: payload?.organization,
        country: payload?.country,
        roleId: payload?.roleId,
        groupId: payload?.groupId
    };
    return applyAccountUpdate(subjectId, input);
}

# Super Admin reset of ANOTHER user's WSO2 IS password — the admin counterpart of
# `akun_saya_service:updateMyPassword`, sharing its validation/apply via `applyPasswordUpdate`. Runs
# as the Super Admin IS account (config:scimAdminUsername/scimAdminPassword). Separate from the data
# update (updateUserAccount) — password is never part of the data-update form.
#
# + subjectId - the WSO2 IS subject id whose password to reset (the TARGET user, not the caller)
# + payload - the new-password request body
# + return - a VALIDATION_ERROR/NOT_FOUND AppError, or an error
public function updateUserPassword(string subjectId, models:PasswordUpdateRequest payload) returns error? {
    models:UserCacheItem? existing = check repositories:findUserCacheBySubjectId(subjectId);
    if existing is () {
        return utils:notFoundError("User dengan subject_id '" + subjectId + "' tidak ditemukan");
    }
    return applyPasswordUpdate(subjectId, payload.password);
}

# Fetches a user's full WSO2 IS identity snapshot — the admin counterpart of
# `akun_saya_service:getMyAccount`, used to prefill the Manajemen User "akun" edit form (Super
# Admin) with the target user's current values before editing.
#
# + subjectId - the WSO2 IS subject id to fetch (the TARGET user, not the caller)
# + return - the current identity snapshot, a NOT_FOUND AppError, or an error
public function getUserAccount(string subjectId) returns models:AkunProfile|error {
    models:UserCacheItem? existing = check repositories:findUserCacheBySubjectId(subjectId);
    if existing is () {
        return utils:notFoundError("User dengan subject_id '" + subjectId + "' tidak ditemukan");
    }
    json? scimResponse = check repositories:scimAdminGet(subjectId);
    if scimResponse is () {
        return utils:notFoundError("Akun WSO2 IS untuk user ini tidak ditemukan");
    }
    return parseAkunProfile(subjectId, scimResponse);
}

# Validates an optional role reference: when present, it must be an existing role.
#
# + roleId - the optional portal role id
# + return - the normalized role id (() when absent), a VALIDATION_ERROR AppError, or an error
function ensureRoleExists(int? roleId) returns int?|error {
    if roleId is () {
        return ();
    }
    models:Role? role = check repositories:findRoleById(roleId);
    if role is () {
        return utils:validationError("Role tidak ditemukan");
    }
    return roleId;
}

# ===== Login-time user_cache sync =====
#
# Best-effort mirror of a successful login's decoded id_token claims into `user_cache`, called from
# `services:exchangeToken` (the choke point both `POST /auth/login` and `POST /auth/token` funnel
# through — see services.bal). Deliberately NOT wired into `services:refresh`: a token refresh is a
# silent session renewal the user never sees, not a new login, so it's excluded to avoid a DB round
# trip on every refresh. Never fails the login: any error is logged and swallowed, same as the other
# write-through paths in this file.

# Skips the write entirely when the cached row already matches the login claims (nama/email/status),
# so a user who logs in repeatedly without changing anything doesn't churn `last_synced_at` on every
# login.
#
# + claims - the decoded id_token claims from a successful login (`models:LoginResponse.user`)
function syncUserCacheFromLogin(map<json> claims) {
    json? subjectRaw = claims["sub"];
    if !(subjectRaw is string) || subjectRaw.trim().length() == 0 {
        return;
    }
    string subjectId = subjectRaw;
    string nama = claimName(claims);
    string email = claimString(claims, "email");
    string status = "ACTIVE";

    models:UserCacheItem?|error existing = repositories:findUserCacheBySubjectId(subjectId);
    if existing is error {
        log:printError("user_cache read failed while syncing login for subject " + subjectId, existing);
        return;
    }
    if existing is models:UserCacheItem
            && existing.nama == nama && existing.email == email && existing.status == status {
        return;
    }

    error? cacheErr = repositories:upsertUserCache(subjectId, nama, email, status);
    if cacheErr is error {
        log:printError("user_cache write-through failed after login for subject " + subjectId, cacheErr);
    }
}

# + claims - the decoded id_token claims
# + key - the claim key to read
# + return - the string claim value, or "" if absent/not a string
function claimString(map<json> claims, string key) returns string {
    json? v = claims[key];
    return v is string ? v : "";
}

# Resolves a display name from the decoded id_token claims. Prefers the combined OIDC `name` claim;
# WSO2 doesn't always release it even under the `profile` scope, so falls back to joining
# `given_name` + `family_name` (also `profile`-scoped claims) when `name` is absent.
#
# + claims - the decoded id_token claims
# + return - the resolved display name, or "" if none of the above are present
function claimName(map<json> claims) returns string {
    string name = claimString(claims, "name");
    if name.trim().length() > 0 {
        return name;
    }
    string given = claimString(claims, "given_name");
    string family = claimString(claims, "family_name");
    string joined = (given + " " + family).trim();
    return joined;
}
