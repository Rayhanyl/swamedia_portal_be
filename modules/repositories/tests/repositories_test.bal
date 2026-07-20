// The functions in this module make live HTTP calls to WSO2 IS (init/authn/token/logout),
// so they aren't realistically unit-testable without a real IS tenant and credentials.
// Verify them by filling in a local Config.toml with real clientId/clientSecret/redirectUri,
// running `bal run`, and exercising POST /api/v1/auth/login and /api/v1/auth/logout end to end.
