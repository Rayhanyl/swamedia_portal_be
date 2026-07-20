import ballerinax/redis;
import rayha/swamedia_portal_be.config;

# Generic Redis-backed cache for future business processes (session data, rate limiting,
# expensive-lookup caching, etc). Kept intentionally generic — JSON in, JSON out — so any
# module can start using it without designing a new client per feature.

isolated redis:Client? cachedClient = ();

# Lazily creates (once) and returns the shared Redis client. Deliberately lazy — a
# module-level `check new(...)` would connect eagerly and break `bal build`/`bal test`
# for anyone without Redis running locally. The connection is only attempted the first
# time a cache function is actually called.
#
# + return - the shared client, or an error if the connection could not be established
isolated function redisClient() returns redis:Client|error {
    lock {
        redis:Client? existing = cachedClient;
        if existing is redis:Client {
            return existing;
        }

        redis:Client newClient = check new ({
            connection: {
                host: config:redisHost,
                port: config:redisPort,
                password: config:redisPassword.length() > 0 ? config:redisPassword : (),
                options: {
                    database: config:redisDatabase,
                    connectionTimeout: config:redisConnectionTimeoutSeconds
                }
            }
        });
        cachedClient = newClient;
        return newClient;
    }
}

# Stores `value` (JSON-serialized) under `key`.
#
# + key - cache key
# + value - any JSON-serializable value
# + ttlSeconds - time-to-live in seconds; 0 (default) keeps the key until explicitly deleted
# + return - an error if the write (or connecting to Redis) failed
public function cacheSet(string key, json value, int ttlSeconds = 0) returns error? {
    redis:Client rc = check redisClient();
    string serialized = value.toJsonString();
    if ttlSeconds > 0 {
        _ = check rc->setEx(key, serialized, ttlSeconds);
    } else {
        _ = check rc->set(key, serialized);
    }
}

# Reads and JSON-deserializes the value stored at `key`.
#
# + key - cache key
# + return - the deserialized value, `()` on cache miss, or an error if the read failed
public function cacheGet(string key) returns json|error {
    redis:Client rc = check redisClient();
    string? raw = check rc->get(key);
    if raw is () {
        return ();
    }
    return check raw.fromJsonString();
}

# Deletes one or more keys. Safe to call on keys that don't exist.
#
# + keys - cache keys to delete
# + return - an error if the delete (or connecting to Redis) failed
public function cacheDelete(string... keys) returns error? {
    redis:Client rc = check redisClient();
    _ = check rc->del(keys);
}
