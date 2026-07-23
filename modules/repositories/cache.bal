import ballerina/time;
import ballerinax/redis;
import rayha/swamedia_portal_be.config;

# Generic Redis-backed cache for future business processes (session data, rate limiting,
# expensive-lookup caching, etc). Kept intentionally generic — JSON in, JSON out — so any
# module can start using it without designing a new client per feature.

// Bundled into one record so the `lock` below only ever touches a single isolated variable
// (Ballerina rejects a lock body that accesses two separate lock-restricted globals).
type RedisClientState record {|
    redis:Client? 'client = ();
    int lastFailureEpochSeconds = 0;
|};

isolated RedisClientState redisState = {};

# How long to wait after a failed connection attempt before trying again. Without this, every
# cache call made while Redis is down (e.g. every permission check, every login) triggers its
# own `new redis:Client(...)` — each failed attempt spins up its own Lettuce timer/event-loop
# threads that are never cleaned up (the connector has no handle to close on a failed connect).
# Under real request volume that leaks hundreds of threads within minutes and starves the whole
# JVM, so *every* HTTP request — including ones that never touch Redis — starts timing out.
# Seen in practice: an idle dev backend with Redis down accumulated 350+ threads and every route,
# even an unauthenticated ping, started failing with "Idle timeout triggered before initiating
# outbound response". Capping retries to once per cooldown window bounds the damage to one
# doomed client per window instead of one per request.
const int REDIS_RECONNECT_COOLDOWN_SECONDS = 30;

# Lazily creates (once) and returns the shared Redis client. Deliberately lazy — a
# module-level `check new(...)` would connect eagerly and break `bal build`/`bal test`
# for anyone without Redis running locally. The connection is only attempted the first
# time a cache function is actually called, and at most once per
# `REDIS_RECONNECT_COOLDOWN_SECONDS` while it keeps failing (see rationale above).
#
# + return - the shared client, or an error if the connection could not be established
isolated function redisClient() returns redis:Client|error {
    lock {
        redis:Client? existing = redisState.'client;
        if existing is redis:Client {
            return existing;
        }

        int nowEpochSeconds = time:utcNow()[0];
        if nowEpochSeconds - redisState.lastFailureEpochSeconds < REDIS_RECONNECT_COOLDOWN_SECONDS {
            return error("Redis unavailable (last connection attempt failed recently, cooling down)");
        }

        redis:Client|error newClient = new ({
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
        if newClient is error {
            redisState.lastFailureEpochSeconds = nowEpochSeconds;
            return newClient;
        }
        redisState.'client = newClient;
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
