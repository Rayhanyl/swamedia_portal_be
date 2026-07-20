import ballerina/sql;
import ballerinax/postgresql;
import rayha/swamedia_portal_be.models;

# ===== Sales Unit — Proyek Tags repository =====
#
# All access to the `proyek_tags` junction (many-to-many proyek <-> tags). The junction carries only
# the two ids (composite PK, no audit, no is_deleted), so attaches are physical rows and detaches
# are physical deletes. Tag display fields are joined from `tags` (only non-deleted tags are
# surfaced). Parameterized `sql:ParameterizedQuery` templates only.

# Lists the (non-deleted) tags currently attached to a proyek, ordered by tag id.
#
# + proyekId - the owning proyek id
# + return - the attached tags, or an error
public function findTagsByProyek(int proyekId) returns models:ProyekTag[]|error {
    postgresql:Client dbc = check dbClient();
    return from models:ProyekTag t in dbc->query(`
            SELECT pt.tags_id AS "tagsId", tg.kode, tg.nama, tg.unit_id AS "unitId"
            FROM proyek_tags pt
            JOIN tags tg ON tg.id = pt.tags_id
            WHERE pt.proyek_id = ${proyekId} AND tg.is_deleted = false
            ORDER BY pt.tags_id ASC`, models:ProyekTag)
        select t;
}

# Returns whether a proyek is already attached to a given tag.
#
# + proyekId - the proyek id
# + tagsId - the tag id
# + return - true if the junction row exists, or an error
public function proyekTagExists(int proyekId, int tagsId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    boolean exists = check dbc->queryRow(
        `SELECT EXISTS(SELECT 1 FROM proyek_tags WHERE proyek_id = ${proyekId} AND tags_id = ${tagsId})`);
    return exists;
}

# Attaches a tag to a proyek, idempotently (ON CONFLICT DO NOTHING — re-attaching an existing tag is
# a no-op, never an error).
#
# + proyekId - the proyek id
# + tagsId - the tag id
# + return - (), or an error
public function attachProyekTag(int proyekId, int tagsId) returns error? {
    postgresql:Client dbc = check dbClient();
    _ = check dbc->execute(`
        INSERT INTO proyek_tags (proyek_id, tags_id) VALUES (${proyekId}, ${tagsId})
        ON CONFLICT (proyek_id, tags_id) DO NOTHING`);
    return ();
}

# Detaches a tag from a proyek (physical delete of the junction row).
#
# + proyekId - the proyek id
# + tagsId - the tag id
# + return - true if a row was deleted, false if it wasn't attached, or an error
public function detachProyekTag(int proyekId, int tagsId) returns boolean|error {
    postgresql:Client dbc = check dbClient();
    sql:ExecutionResult result = check dbc->execute(
        `DELETE FROM proyek_tags WHERE proyek_id = ${proyekId} AND tags_id = ${tagsId}`);
    int? affected = result.affectedRowCount;
    return affected is int && affected > 0;
}

# Replaces a proyek's entire tag set atomically: deletes all its current junction rows and inserts
# the given ids (already validated + de-duplicated by the service) in a single transaction. An empty
# `tagsIds` clears all tags.
#
# + proyekId - the proyek id
# + tagsIds - the complete desired set of tag ids
# + return - (), or an error
public function replaceProyekTags(int proyekId, int[] tagsIds) returns error? {
    postgresql:Client dbc = check dbClient();
    transaction {
        _ = check dbc->execute(`DELETE FROM proyek_tags WHERE proyek_id = ${proyekId}`);
        foreach int tagsId in tagsIds {
            _ = check dbc->execute(
                `INSERT INTO proyek_tags (proyek_id, tags_id) VALUES (${proyekId}, ${tagsId})`);
        }
        check commit;
    }
    return ();
}
