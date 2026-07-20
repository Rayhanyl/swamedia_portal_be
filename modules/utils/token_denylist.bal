import ballerina/crypto;
import ballerina/jwt;
import ballerina/time;

# In-memory set of access tokens invalidated via `/api/v1/auth/revoke` or
# `/api/v1/auth/logout`, keyed by SHA-256 hash of the raw token (same hashing convention as
# the userinfo cache key in services.bal) mapped to the token's own `exp` (epoch seconds).
#
# Deliberately in-memory rather than Redis: this only needs to answer "was this exact token
# explicitly revoked" for as long as it would otherwise still pass JWKS validation, and it
# sits in front of that JWKS check (see TokenDenylistInterceptor in main.bal) rather than
# replacing it. Trade-off: cleared on restart, and not shared if the backend is ever scaled
# to multiple instances.
isolated map<int> denylistedTokens = {};

# Marks a token as revoked so `isTokenDenylisted` rejects it until its own expiry.
#
# + token - the raw access token to denylist
public isolated function denylistToken(string token) {
    string key = denylistKey(token);
    int expiry = tokenExpiryEpoch(token);
    lock {
        denylistedTokens[key] = expiry;
    }
}

# + token - the raw access token to check
# + return - true if the token was explicitly revoked/logged-out and hasn't expired yet
public isolated function isTokenDenylisted(string token) returns boolean {
    string key = denylistKey(token);
    lock {
        int? expiry = denylistedTokens[key];
        if expiry is () {
            return false;
        }
        if expiry <= time:utcNow()[0] {
            // Naturally expired since being denylisted — no longer worth tracking.
            _ = denylistedTokens.remove(key);
            return false;
        }
        return true;
    }
}

isolated function denylistKey(string token) returns string => crypto:hashSha256(token.toBytes()).toBase16();

# Falls back to now+1h if the token's `exp` claim can't be read (e.g. an opaque refresh
# token), so a non-JWT value passed to `denylistToken` doesn't stay tracked forever.
#
# + token - the token to inspect
# + return - the token's `exp` claim (epoch seconds), or now+3600 as a fallback
isolated function tokenExpiryEpoch(string token) returns int {
    [jwt:Header, jwt:Payload]|jwt:Error decoded = jwt:decode(token);
    if decoded is jwt:Error {
        return time:utcNow()[0] + 3600;
    }
    int? exp = decoded[1].exp;
    return exp is int ? exp : time:utcNow()[0] + 3600;
}
