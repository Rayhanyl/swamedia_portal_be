import ballerina/lang.array;
import ballerina/test;
import rayha/swamedia_portal_be.config;
import rayha/swamedia_portal_be.models;

// Classic jwt.io example token — header {"alg":"HS256","typ":"JWT"},
// payload {"sub":"1234567890","name":"John Doe","iat":1516239022}.
// Only used to exercise decoding, signature is not verified.
const SAMPLE_JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
    "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ." +
    "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";

@test:Config {}
function testDecodeIdTokenClaims() {
    map<json>|error claims = decodeIdTokenClaims(SAMPLE_JWT);

    test:assertTrue(claims is map<json>, "expected a decoded claims map");
    if claims is map<json> {
        test:assertEquals(claims["sub"], "1234567890");
        test:assertEquals(claims["name"], "John Doe");
    }
}

@test:Config {}
function testDecodeIdTokenClaimsWithInvalidToken() {
    map<json>|error claims = decodeIdTokenClaims("not-a-valid-jwt");
    test:assertTrue(claims is error, "expected decoding to fail for a malformed token");
}

@test:Config {}
function testSuccessResponse() {
    models:ApiResponse response = successResponse({id: 1}, "Login berhasil");

    test:assertTrue(response.success);
    test:assertEquals(response.message, "Login berhasil");
    test:assertEquals(response.errors, ());
}

@test:Config {}
function testErrorResponse() {
    models:ApiResponse response = errorResponse("NOT_FOUND", "Data tidak ditemukan");

    test:assertFalse(response.success);
    models:ErrorDetail? errors = response.errors;
    test:assertTrue(errors is models:ErrorDetail);
    if errors is models:ErrorDetail {
        test:assertEquals(errors.code, "NOT_FOUND");
        test:assertEquals(errors.message, "Data tidak ditemukan");
    }
}

@test:Config {}
function testUnauthorizedError() {
    models:AppError err = unauthorizedError("Username atau password salah");
    test:assertEquals(err.detail().code, "UNAUTHORIZED");
    test:assertEquals(err.detail().statusCode, 401);
}

@test:Config {}
function testValidationError() {
    models:AppError err = validationError("Field wajib diisi");
    test:assertEquals(err.detail().code, "VALIDATION_ERROR");
    test:assertEquals(err.detail().statusCode, 400);
}

@test:Config {}
function testInternalError() {
    models:AppError err = internalError("Terjadi kesalahan pada server");
    test:assertEquals(err.detail().code, "INTERNAL_ERROR");
    test:assertEquals(err.detail().statusCode, 500);
}

@test:Config {}
function testBasicAuthHeaderDecodesBackToCredentials() returns error? {
    string header = basicAuthHeader();
    test:assertTrue(header.startsWith("Basic "));

    string encoded = header.substring(6);
    byte[] decoded = check array:fromBase64(encoded);
    string credentials = check string:fromBytes(decoded);
    test:assertEquals(credentials, config:clientId + ":" + config:clientSecret);
}

@test:Config {}
function testBearerTokenValid() {
    string|models:AppError token = bearerToken("Bearer abc.def.ghi");
    test:assertTrue(token is string);
    if token is string {
        test:assertEquals(token, "abc.def.ghi");
    }
}

@test:Config {}
function testBearerTokenMissingHeader() {
    string|models:AppError token = bearerToken(());
    test:assertTrue(token is models:AppError);
    if token is models:AppError {
        test:assertEquals(token.detail().statusCode, 401);
    }
}

@test:Config {}
function testBearerTokenWrongScheme() {
    string|models:AppError token = bearerToken("Basic abc");
    test:assertTrue(token is models:AppError);
    if token is models:AppError {
        test:assertEquals(token.detail().statusCode, 401);
    }
}
