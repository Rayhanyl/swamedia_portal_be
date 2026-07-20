import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Konfigurasi Sistem — sys_config repository =====
#
# All access to the `sys_config` table (key-value global settings, PK = `key`). Parameterized
# `sql:ParameterizedQuery` templates only. This is a fixed, seeded registry actually read by name
# throughout the codebase — no insert/delete function exists here; only the `value` of an existing
# key can be updated.

# Fetches every sys_config row, optionally filtered by a case-insensitive search over key or
# deskripsi, ordered by key for stable display.
#
# + search - optional case-insensitive filter on key or deskripsi
# + return - the matching rows, or an error
public function findAllSysConfig(string? search) returns models:SysConfig[]|error {
    postgresql:Client dbc = check dbClient();

    sql:ParameterizedQuery[] parts = [
        `SELECT key AS "key", value, deskripsi, updated_at::text AS "updatedAt", updated_by AS "updatedBy"
         FROM sys_config WHERE 1 = 1`
    ];
    if search is string && search.trim().length() > 0 {
        string pattern = "%" + search.trim() + "%";
        parts.push(` AND (key ILIKE ${pattern} OR deskripsi ILIKE ${pattern})`);
    }
    parts.push(` ORDER BY key ASC`);
    sql:ParameterizedQuery query = sql:queryConcat(...parts);

    return from models:SysConfig c in dbc->query(query, models:SysConfig) select c;
}

# Fetches a single sys_config row by key.
#
# + configKey - the setting's key
# + return - the row, `()` if not found, or an error
public function findSysConfigByKey(string configKey) returns models:SysConfig?|error {
    postgresql:Client dbc = check dbClient();
    models:SysConfig|sql:Error result = dbc->queryRow(`
        SELECT key AS "key", value, deskripsi, updated_at::text AS "updatedAt", updated_by AS "updatedBy"
        FROM sys_config WHERE key = ${configKey}`, models:SysConfig);
    if result is sql:NoRowsError {
        return ();
    }
    return result;
}

# Updates the value of an existing sys_config row and returns the updated row.
#
# + configKey - the setting's key
# + value - the new value, or () to clear it
# + updatedBy - the `sub` claim of the caller
# + return - the updated row, `()` if the key does not exist, or an error
public function updateSysConfigValue(string configKey, string? value, string updatedBy)
        returns models:SysConfig?|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(`
        UPDATE sys_config SET value = ${value}, updated_by = ${updatedBy}, updated_at = now()
        WHERE key = ${configKey}`);
    int? affected = result.affectedRowCount;
    if !(affected is int && affected > 0) {
        return ();
    }
    return findSysConfigByKey(configKey);
}
