import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import rayha/swamedia_portal_be.config;

# Shared PostgreSQL client for the primary application database. Lazy-initialized for
# the same reason as the Redis client in cache.bal — keeps `bal build`/`bal test` free
# of a live DB dependency.

isolated postgresql:Client? cachedDbClient = ();

# Lazily creates (once) and returns the shared PostgreSQL client.
#
# + return - the shared client, or an error if the connection could not be established
public isolated function dbClient() returns postgresql:Client|error {
    lock {
        postgresql:Client? existing = cachedDbClient;
        if existing is postgresql:Client {
            return existing;
        }

        postgresql:Client newClient = check new (
            host = config:dbHost,
            port = config:dbPort,
            database = config:dbName,
            username = config:dbUser,
            password = config:dbPassword,
            connectionPool = {maxOpenConnections: config:dbMaxOpenConnections}
        );
        cachedDbClient = newClient;
        return newClient;
    }
}
