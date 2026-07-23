import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;
import rayha/swamedia_portal_be.utils;

# ===== Konfigurasi Sistem service =====
#
# Business rules for sys_config (global key-value settings). Domain failures are `models:AppError`;
# infrastructure failures propagate as plain `error`. This is a fixed, seeded registry — there is no
# create/delete here, only listing and updating the `value` of an existing key.

# Lists all sys_config rows, optionally filtered by search.
#
# + search - optional case-insensitive filter on key or deskripsi
# + return - the matching rows, or an error
public function getSysConfig(string? search) returns models:SysConfig[]|error {
    return repositories:findAllSysConfig(search);
}

# Fetches a single sys_config row by key.
#
# + configKey - the setting's key
# + return - the row, a NOT_FOUND AppError if it does not exist, or an error
public function getSysConfigByKey(string configKey) returns models:SysConfig|error {
    models:SysConfig? config = check repositories:findSysConfigByKey(configKey);
    if config is () {
        return utils:notFoundError("Konfigurasi dengan key '" + configKey + "' tidak ditemukan");
    }
    return config;
}

# Updates the value of an existing sys_config key.
#
# + configKey - the setting's key
# + payload - the update request body
# + subject - the caller's `sub` claim, stored as updated_by
# + return - the updated row, a NOT_FOUND AppError if the key does not exist, or an error
public function updateSysConfigValue(string configKey, models:SysConfigUpdateRequest payload, string subject, string? ipAddress = ())
        returns models:SysConfig|error {
    models:SysConfig? existing = check repositories:findSysConfigByKey(configKey);
    models:SysConfig? updated = check repositories:updateSysConfigValue(configKey, payload.value, subject);
    if updated is () {
        return utils:notFoundError("Konfigurasi dengan key '" + configKey + "' tidak ditemukan");
    }
    // sys_config is keyed by its string `key`, not a numeric id — that key is what lands in
    // audit_log.record_id (varchar(60), so it fits).
    logAudit("sys_config", configKey, "UPDATE", existing is () ? () : existing.toJson(), updated.toJson(), subject, ipAddress);
    return updated;
}
