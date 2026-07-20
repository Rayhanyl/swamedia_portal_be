import ballerina/time;

# ===== WSO2 IS — Init step (`POST /oauth2/authorize`) =====
#
# These types deserialize live WSO2 IS responses via `cloneWithType`, so they're left open
# (no `{| |}`) — WSO2 may send extra top-level fields (e.g. `links`) we don't model, and a
# closed record would reject the whole conversion when that happens.

# + authenticatorId - unique id of this authenticator option, returned by WSO2 IS
# + authenticator - display name of the authenticator (e.g. "Username & Password")
# + idp - identity provider this authenticator belongs to (e.g. "LOCAL")
# + metadata - optional authenticator-specific metadata WSO2 IS may include
# + requiredParams - optional list of parameter names this authenticator requires
public type AuthInitAuthenticator record {
    string authenticatorId;
    string authenticator;
    string idp;
    map<json> metadata?;
    string[] requiredParams?;
};

# + stepType - the type of the next authentication step (e.g. "AUTHENTICATOR_PROMPT")
# + authenticators - the authenticator options offered for this step
public type AuthInitNextStep record {
    string stepType;
    AuthInitAuthenticator[] authenticators;
};

# + flowId - the WSO2 IS flow id to carry through the remaining login steps
# + flowStatus - current status of the authentication flow
# + flowType - the type of flow (e.g. "AUTHENTICATION")
# + nextStep - the step the client must complete next
public type AuthInitResponse record {
    string flowId;
    string flowStatus;
    string flowType;
    AuthInitNextStep nextStep;
};

# ===== WSO2 IS — Authenticate step (`POST /oauth2/authn`) =====

# + code - the authorization code issued on successful authentication
# + session_state - optional session state returned by WSO2 IS
public type AuthnData record {
    string code;
    string session_state?;
};

# + flowStatus - the flow status after submitting credentials (e.g. "SUCCESS_COMPLETED")
# + authData - present when flowStatus is SUCCESS_COMPLETED; carries the authorization code
public type AuthnResponse record {
    string flowStatus;
    AuthnData authData?;
};

# ===== WSO2 IS — Token step (`POST /oauth2/token`) =====

# + access_token - the issued OAuth2 access token
# + refresh_token - the issued refresh token, if the grant returns one
# + id_token - the issued OIDC id_token, if requested
# + token_type - the token type (typically "Bearer")
# + expires_in - access token lifetime in seconds
# + scope - the granted scope, if returned
public type TokenResponse record {
    string access_token;
    string refresh_token?;
    string id_token?;
    string token_type;
    int expires_in;
    string scope?;
};

# ===== Public API — Init =====

# Response of POST /api/v1/auth/init — surfaces the flowId and the authenticators the
# Identity Server offers, without exposing any further IS internals.
#
# + flowId - the flow id to pass to subsequent login calls
# + authenticators - the authenticator options the Identity Server offers
public type InitResponse record {|
    string flowId;
    AuthInitAuthenticator[] authenticators;
|};

# ===== Public API — Login =====

# + username - the user's login username
# + password - the user's login password
public type LoginRequest record {|
    string username;
    string password;
|};

# Request of POST /api/v1/auth/token — exchanges an authorization code for tokens.
#
# + code - the authorization code obtained from the login/init flow
public type TokenExchangeRequest record {|
    string code;
|};

# Request of POST /api/v1/auth/refresh — trades a refresh token for a fresh token set.
#
# + refreshToken - the refresh token obtained at login time
public type RefreshRequest record {|
    string refreshToken;
|};

# Request of POST /api/v1/auth/introspect — checks the state of a token.
#
# + token - the access or refresh token to inspect
# + tokenTypeHint - optional hint ("access_token" or "refresh_token")
public type IntrospectRequest record {|
    string token;
    string tokenTypeHint?;
|};

# Response of the introspection endpoint. Open record: WSO2 returns `active` plus a
# variable set of claims (scope, username, exp, client_id, ...) depending on the token.
#
# + active - whether the token is currently active
public type IntrospectResponse record {
    boolean active;
};

# Request of POST /api/v1/auth/revoke — revokes an access or refresh token.
#
# + token - the access or refresh token to revoke
# + tokenTypeHint - optional hint ("access_token" or "refresh_token")
public type RevokeRequest record {|
    string token;
    string tokenTypeHint?;
|};

# + accessToken - the issued access token
# + refreshToken - the issued refresh token, if any
# + idToken - the issued id_token, if any
# + tokenType - the token type (typically "Bearer")
# + expiresIn - access token lifetime in seconds
# + scope - the granted scope, if any
# + user - decoded id_token claims describing the logged-in user
public type LoginResponse record {|
    string accessToken;
    string refreshToken?;
    string idToken?;
    string tokenType;
    int expiresIn;
    string scope?;
    map<json> user;
|};

# ===== Public API — Logout =====

# + idToken - the id_token obtained at login time, required by WSO2 IS to end the session
# + accessToken - optional access token to denylist locally alongside the IS logout
public type LogoutRequest record {|
    string idToken;
    string accessToken?;
|};

# ===== API response envelope (see note/API-Response-Standard.md) =====

# + code - machine-readable error code (SCREAMING_SNAKE_CASE)
# + message - human-readable error message
# + details - optional additional error context
public type ErrorDetail record {|
    string code;
    string message;
    anydata details?;
|};

# + page - current 1-based page number
# + limit - page size
# + totalItems - total number of matching rows across all pages
# + totalPages - total number of pages
public type Pagination record {|
    int page;
    int 'limit;
    int totalItems;
    int totalPages;
|};

# + timestamp - response generation time (UTC, ISO 8601)
# + requestId - optional request correlation id
# + pagination - optional pagination metadata, present on list endpoints
public type ResponseMeta record {|
    string timestamp = time:utcToString(time:utcNow());
    string? requestId?;
    Pagination? pagination?;
|};

# + success - true if the request succeeded, false otherwise
# + message - human-readable summary of the result
# + data - the response payload, absent/null on error
# + errors - error detail, null on success
# + meta - response metadata (timestamp, pagination, ...)
public type ApiResponse record {|
    boolean success;
    string message;
    anydata data?;
    ErrorDetail? errors = ();
    ResponseMeta meta?;
|};

# Distinct error type carrying the HTTP status code and machine-readable code
# alongside the error message, so resource functions can respond consistently.
#
# + code - machine-readable error code (SCREAMING_SNAKE_CASE)
# + statusCode - the HTTP status code to respond with
public type AppError distinct error<record {|
    string code;
    int statusCode;
|}>;

# ===== Master Data — Unit =====

# A unit row as returned to the client. Audit columns are optional: the list endpoint
# selects only the core fields, while the detail endpoint also fills the audit fields.
# `tipeUnit` is read-only/computed (mirrors view `v_unit`): STRUKTURAL if the unit has an
# active child unit, OPERASIONAL otherwise (leaf).
#
# + id - primary key
# + namaUnit - unit name
# + kodeUnit - unique unit code
# + parentUnitId - parent unit id, or () for a top-level unit
# + tipeUnit - computed: STRUKTURAL if the unit has an active child, OPERASIONAL otherwise
# + status - AKTIF / TIDAK_AKTIF
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type Unit record {|
    int id;
    string namaUnit;
    string kodeUnit;
    int? parentUnitId;
    string tipeUnit;
    string status;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/units. `status` defaults to "AKTIF" when omitted;
# `parentUnitId` is optional/nullable (a top-level unit has no parent). `kodeUnit` is
# required — `unit.kode_unit` is NOT NULL UNIQUE in the DB.
#
# + namaUnit - unit name
# + kodeUnit - unique unit code
# + parentUnitId - optional parent unit id
# + status - optional status, defaults to "AKTIF"
public type UnitCreateRequest record {|
    string namaUnit;
    string kodeUnit;
    int? parentUnitId?;
    string status?;
|};

# Request body for PUT /api/v1/master/units/{id} — a full replace of the mutable fields.
#
# + namaUnit - new unit name
# + kodeUnit - new unique unit code
# + parentUnitId - new parent unit id, or () to clear it
# + status - new status
public type UnitUpdateRequest record {|
    string namaUnit;
    string kodeUnit;
    int? parentUnitId?;
    string status;
|};

# One node of the unit hierarchy returned by GET /api/v1/master/units/tree.
#
# + id - unit id
# + namaUnit - unit name
# + kodeUnit - unit code
# + parentUnitId - parent unit id, or () for a root node
# + tipeUnit - computed: STRUKTURAL if the unit has an active child, OPERASIONAL otherwise
# + status - AKTIF / TIDAK_AKTIF
# + children - direct child nodes
public type UnitTreeNode record {|
    int id;
    string namaUnit;
    string kodeUnit;
    int? parentUnitId;
    string tipeUnit;
    string status;
    UnitTreeNode[] children;
|};

# Result of a paginated unit list query: the page of items plus the pagination metadata
# the resource layer wraps into `meta.pagination`.
#
# + items - the page of units
# + pagination - pagination metadata
public type UnitListResult record {|
    Unit[] items;
    Pagination pagination;
|};

# ===== Master Data — Industri =====

# An industri row as returned to the client. Audit columns are optional: the list endpoint
# selects only the core fields, while the detail endpoint also fills the audit fields.
#
# + id - primary key
# + kode - unique industri code
# + nama - industri name
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type Industri record {|
    int id;
    string kode;
    string nama;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/industries.
#
# + kode - unique industri code
# + nama - industri name
public type IndustriCreateRequest record {|
    string kode;
    string nama;
|};

# Request body for PUT /api/v1/master/industries/{id} — a full replace of the mutable fields.
#
# + kode - new unique industri code
# + nama - new industri name
public type IndustriUpdateRequest record {|
    string kode;
    string nama;
|};

# Result of a paginated industri list query: the page of items plus the pagination metadata.
#
# + items - the page of industries
# + pagination - pagination metadata
public type IndustriListResult record {|
    Industri[] items;
    Pagination pagination;
|};

# ===== Master Data — Tags (labels for Proyek) =====

# A tag row as returned to the client. Audit columns are optional: the list endpoint selects
# only core fields, while the detail endpoint also fills the audit fields.
#
# + id - primary key
# + kode - tag code (unique per unit)
# + nama - tag name
# + unitId - owning unit id, or () for a global tag
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type Tags record {|
    int id;
    string kode;
    string nama;
    int? unitId;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/tags. `unitId` is optional/nullable (a global tag has no unit).
#
# + kode - tag code
# + nama - tag name
# + unitId - optional owning unit id
public type TagsCreateRequest record {|
    string kode;
    string nama;
    int? unitId?;
|};

# Request body for PUT /api/v1/master/tags/{id} — a full replace of the mutable fields.
#
# + kode - new tag code
# + nama - new tag name
# + unitId - new owning unit id, or () to clear it
public type TagsUpdateRequest record {|
    string kode;
    string nama;
    int? unitId?;
|};

# Result of a paginated tags list query: the page of items plus the pagination metadata.
#
# + items - the page of tags
# + pagination - pagination metadata
public type TagsListResult record {|
    Tags[] items;
    Pagination pagination;
|};

# ===== Master Data — Resource Tags (labels for Resource Unit) =====

# A resource tag row as returned to the client. Audit columns are optional (detail only).
#
# + id - primary key
# + kode - tag code (unique per unit)
# + nama - tag name
# + unitId - owning unit id, or () for a global tag
# + deskripsi - optional description
# + status - AKTIF / TIDAK_AKTIF
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type ResourceTags record {|
    int id;
    string kode;
    string nama;
    int? unitId;
    string? deskripsi;
    string status;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/resource-tags. `status` defaults to "AKTIF" when omitted.
#
# + kode - tag code
# + nama - tag name
# + unitId - optional owning unit id
# + deskripsi - optional description
# + status - optional status, defaults to "AKTIF"
public type ResourceTagsCreateRequest record {|
    string kode;
    string nama;
    int? unitId?;
    string? deskripsi?;
    string status?;
|};

# Request body for PUT /api/v1/master/resource-tags/{id} — a full replace of the mutable fields.
#
# + kode - new tag code
# + nama - new tag name
# + unitId - new owning unit id, or () to clear it
# + deskripsi - new description, or () to clear it
# + status - new status
public type ResourceTagsUpdateRequest record {|
    string kode;
    string nama;
    int? unitId?;
    string? deskripsi?;
    string status;
|};

# Result of a paginated resource-tags list query: the page of items plus the pagination metadata.
#
# + items - the page of resource tags
# + pagination - pagination metadata
public type ResourceTagsListResult record {|
    ResourceTags[] items;
    Pagination pagination;
|};

# ===== Master Data — Kategori Surat (letter-category master, DR-01..DR-09) =====

# A kategori surat row as returned to the client. `isDefault` is read-only from the API's
# perspective: it flags the 9 seeded built-in categories (delete disabled in the UI) and is
# only ever set by seeding/migration, never by create/update endpoints. `status` (AKTIF /
# TIDAK_AKTIF) controls whether the category can be picked for a NEW letter — TIDAK_AKTIF
# categories stay valid on letters that already used them (distinct from soft-delete).
#
# + id - primary key
# + kode - unique category code (format DR-XX)
# + nama - category name
# + status - AKTIF / TIDAK_AKTIF
# + isDefault - true for the 9 seeded built-in categories (read-only)
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type KategoriSurat record {|
    int id;
    string kode;
    string nama;
    string status;
    boolean isDefault;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/kategori-surat. Deliberately an OPEN record (no `{| |}`)
# and without an `isDefault` field: any `isDefault` sent by the client lands in the rest fields
# and is silently ignored — new categories are always created with is_default = false.
# `status` defaults to "AKTIF" when omitted.
#
# + kode - category code (format DR-XX)
# + nama - category name
# + status - optional status, defaults to "AKTIF"
public type KategoriSuratCreateRequest record {
    string kode;
    string nama;
    string status?;
};

# Request body for PUT /api/v1/master/kategori-surat/{id}. Open record for the same reason:
# `isDefault` cannot be changed via the API, so it is ignored if sent.
#
# + kode - new category code (format DR-XX)
# + nama - new category name
# + status - new status
public type KategoriSuratUpdateRequest record {
    string kode;
    string nama;
    string status;
};

# Result of a paginated kategori-surat list query: the page of items plus the pagination metadata.
#
# + items - the page of kategori surat
# + pagination - pagination metadata
public type KategoriSuratListResult record {|
    KategoriSurat[] items;
    Pagination pagination;
|};

# ===== Master Data — Jabatan (jabatan_master) =====

# Compact Jabatan projection embedded in Karyawan responses (JOIN to jabatan_master).
# Always present — `karyawan.jabatan_id` is NOT NULL in the DB.
#
# + id - jabatan_master id
# + namaJabatan - jabatan name
# + kategori - jabatan category
public type JabatanRef record {|
    int id;
    string namaJabatan;
    string kategori;
|};

# A jabatan_master row as returned by GET /api/v1/master/jabatan — the dropdown source for
# the Karyawan form. Read-only from the API's perspective: no create/update/delete endpoint.
#
# + id - primary key
# + namaJabatan - jabatan name
# + kategori - jabatan category
# + unitTerkaitId - optional unit this jabatan is tied to
# + isKombinasiUnit - true if this jabatan combines with a unit name in the UI (e.g. "Assistant Manager")
# + status - AKTIF / TIDAK_AKTIF
public type JabatanMaster record {|
    int id;
    string namaJabatan;
    string kategori;
    int? unitTerkaitId;
    boolean isKombinasiUnit;
    string status;
|};

# ===== Master Data — Karyawan =====

# A karyawan row as shown in the LIST view. Deliberately EXCLUDES `subjectId`: that field
# links a karyawan to their WSO2 IS identity and is privacy-sensitive, so it must never appear
# in list responses — only in the by-id detail response (see `KaryawanDetail`).
#
# + id - primary key
# + nik - unique employee id number
# + nama - employee name
# + jabatan - joined jabatan_master projection
# + unitId - owning unit id
# + email - employee email
# + noHp - optional phone number
# + tanggalMasuk - optional join date (YYYY-MM-DD)
# + status - AKTIF / TIDAK_AKTIF
public type KaryawanListItem record {|
    int id;
    string nik;
    string nama;
    JabatanRef jabatan;
    int unitId;
    string email;
    string? noHp;
    string? tanggalMasuk;
    string status;
|};

# A karyawan row as shown in the DETAIL (by-id) view. Includes `subjectId` and audit columns.
# `subjectId` is nullable — a karyawan may exist without a portal account.
#
# + id - primary key
# + nik - unique employee id number
# + nama - employee name
# + jabatan - joined jabatan_master projection
# + unitId - owning unit id
# + email - employee email
# + noHp - optional phone number
# + tanggalMasuk - optional join date (YYYY-MM-DD)
# + status - AKTIF / TIDAK_AKTIF
# + subjectId - optional linked WSO2 IS user id (privacy-sensitive; detail view only)
# + createdAt - creation timestamp
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim
# + updatedBy - last updater's `sub` claim, or ()
public type KaryawanDetail record {|
    int id;
    string nik;
    string nama;
    JabatanRef jabatan;
    int unitId;
    string email;
    string? noHp;
    string? tanggalMasuk;
    string status;
    string? subjectId;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/karyawan. `jabatanId` is required — `karyawan.jabatan_id`
# is NOT NULL in the DB (FK to jabatan_master). `subjectId` is optional/nullable (see the
# security note in karyawan_service on why it is sensitive despite living in the normal form).
#
# + nik - unique employee id number
# + nama - employee name
# + jabatanId - jabatan_master id (FK)
# + unitId - owning unit id
# + email - employee email
# + noHp - optional phone number
# + tanggalMasuk - optional join date (YYYY-MM-DD)
# + status - optional status, defaults to "AKTIF"
# + subjectId - optional linked WSO2 IS user id
public type KaryawanCreateRequest record {|
    string nik;
    string nama;
    int jabatanId;
    int unitId;
    string email;
    string? noHp?;
    string? tanggalMasuk?;
    string status?;
    string? subjectId?;
|};

# Request body for PUT /api/v1/master/karyawan/{id}. `subjectId` may be set, changed, or
# cleared (send null or an empty string to unlink the portal account).
#
# + nik - new unique employee id number
# + nama - new employee name
# + jabatanId - new jabatan_master id (FK)
# + unitId - new owning unit id
# + email - new employee email
# + noHp - new phone number, or () to clear it
# + tanggalMasuk - new join date, or () to clear it
# + status - new status
# + subjectId - new linked WSO2 IS user id, or ()/empty to unlink
public type KaryawanUpdateRequest record {|
    string nik;
    string nama;
    int jabatanId;
    int unitId;
    string email;
    string? noHp?;
    string? tanggalMasuk?;
    string status;
    string? subjectId?;
|};

# Result of a paginated karyawan list query: the page of list items plus pagination metadata.
#
# + items - the page of karyawan list items
# + pagination - pagination metadata
public type KaryawanListResult record {|
    KaryawanListItem[] items;
    Pagination pagination;
|};

# A karyawan option for lightweight dropdowns (Team Member, Resource Unit, Kontrak Payung
# harga-per-role forms) — GET /api/v1/master/karyawan/dropdown. No pagination.
#
# + id - karyawan id
# + nama - employee name
# + unitNama - joined unit name
public type KaryawanDropdownItem record {|
    int id;
    string nama;
    string unitNama;
|};

# ===== Master Data — Customer =====

# A customer row as shown in the LIST view (raw FK ids only, no joined display names).
#
# + id - primary key
# + nama - customer name
# + amId - optional account manager (karyawan) id
# + industriId - optional industri id
# + statusPeluang - PROSPEK / NEGOSIASI / DEAL / BATAL
# + jenisCustomer - optional customer type (ENTERPRISE / BANKING / BUMN / GOVERNMENT)
public type Customer record {|
    int id;
    string nama;
    int? amId;
    int? industriId;
    string statusPeluang;
    string? jenisCustomer;
|};

# A customer row as shown in the DETAIL (by-id) view. Includes the joined display names of the
# Account Manager (karyawan) and industri, plus audit columns. `amNama`/`industriNama` are
# nullable (the FK may be null, or the referenced row soft-deleted).
#
# + id - primary key
# + nama - customer name
# + amId - optional account manager (karyawan) id
# + amNama - joined account manager name, or () if unset/deleted
# + industriId - optional industri id
# + industriNama - joined industri name, or () if unset/deleted
# + statusPeluang - PROSPEK / NEGOSIASI / DEAL / BATAL
# + jenisCustomer - optional customer type (ENTERPRISE / BANKING / BUMN / GOVERNMENT)
# + createdAt - creation timestamp
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim
# + updatedBy - last updater's `sub` claim, or ()
public type CustomerDetail record {|
    int id;
    string nama;
    int? amId;
    string? amNama;
    int? industriId;
    string? industriNama;
    string statusPeluang;
    string? jenisCustomer;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/customers. `statusPeluang` defaults to "PROSPEK".
#
# + nama - customer name
# + amId - optional account manager (karyawan) id
# + industriId - optional industri id
# + statusPeluang - optional status, defaults to "PROSPEK"
# + jenisCustomer - optional customer type
public type CustomerCreateRequest record {|
    string nama;
    int? amId?;
    int? industriId?;
    string statusPeluang?;
    string? jenisCustomer?;
|};

# Request body for PUT /api/v1/master/customers/{id} — a full replace of the mutable fields.
#
# + nama - new customer name
# + amId - new account manager id, or () to clear it
# + industriId - new industri id, or () to clear it
# + statusPeluang - new status
# + jenisCustomer - new customer type, or () to clear it
public type CustomerUpdateRequest record {|
    string nama;
    int? amId?;
    int? industriId?;
    string statusPeluang;
    string? jenisCustomer?;
|};

# Result of a paginated customer list query: the page of list items plus pagination metadata.
#
# + items - the page of customers
# + pagination - pagination metadata
public type CustomerListResult record {|
    Customer[] items;
    Pagination pagination;
|};

# ===== Master Data — Contact =====

# A contact row as returned to the client. `tipeKontak` is the contact's ROLE
# (UTAMA/AKTIF/PROSPEK), NOT an active/inactive status — soft-delete still uses is_deleted.
# Audit columns are optional: the list endpoint selects only core fields, detail adds audit.
#
# + id - primary key
# + customerId - owning customer id
# + nama - contact name
# + jabatan - optional job title
# + email - optional email
# + telepon - optional phone number
# + tipeKontak - contact role: UTAMA / AKTIF / PROSPEK
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type Contact record {|
    int id;
    int customerId;
    string nama;
    string? jabatan;
    string? email;
    string? telepon;
    string tipeKontak;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/contacts. `tipeKontak` defaults to "AKTIF".
#
# + customerId - owning customer id
# + nama - contact name
# + jabatan - optional job title
# + email - optional email
# + telepon - optional phone number
# + tipeKontak - optional contact role, defaults to "AKTIF"
public type ContactCreateRequest record {|
    int customerId;
    string nama;
    string? jabatan?;
    string? email?;
    string? telepon?;
    string tipeKontak?;
|};

# Request body for PUT /api/v1/master/contacts/{id} — a full replace of the mutable fields.
#
# + customerId - new owning customer id
# + nama - new contact name
# + jabatan - new job title, or () to clear it
# + email - new email, or () to clear it
# + telepon - new phone number, or () to clear it
# + tipeKontak - new contact role
public type ContactUpdateRequest record {|
    int customerId;
    string nama;
    string? jabatan?;
    string? email?;
    string? telepon?;
    string tipeKontak;
|};

# Result of a paginated contact list query: the page of items plus pagination metadata.
#
# + items - the page of contacts
# + pagination - pagination metadata
public type ContactListResult record {|
    Contact[] items;
    Pagination pagination;
|};

# ===== e-Office — Daftar Surat (nomor_surat) =====

# A nomor_surat row as returned to the client ("Daftar Surat" in the UI). Carries the joined
# display fields — kategoriKode/kategoriNama from kategori_surat, kodeProyek/namaProyek from
# proyek (null when proyek_id is null or the proyek was soft-deleted). `tanggal` is the DATE
# column rendered as text (YYYY-MM-DD). `alasanPembatalan`/`isDibatalkan` are always present (even
# for active letters, where alasanPembatalan is null and isDibatalkan is false) since both the list
# and detail queries always select them. Audit columns are optional: the list endpoint selects
# only core+joined fields, while the detail endpoint also fills the audit fields.
#
# + id - primary key
# + kategoriSuratId - kategori_surat id (FK)
# + kategoriKode - joined kategori_surat code
# + kategoriNama - joined kategori_surat name
# + proyekId - optional proyek id
# + kodeProyek - joined proyek code, or () if unset/deleted
# + namaProyek - joined proyek name, or () if unset/deleted
# + tanggal - letter date (YYYY-MM-DD)
# + tahun - numbering year
# + urutan - sequence number within (kategori, tahun)
# + nomor - the generated letter number
# + tujuan - optional recipient
# + perihal - optional subject
# + keterangan - optional notes
# + alasanPembatalan - cancellation reason, or () if not cancelled
# + isDibatalkan - true if the letter has been cancelled
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type NomorSurat record {|
    int id;
    int kategoriSuratId;
    string kategoriKode;
    string kategoriNama;
    int? proyekId;
    string? kodeProyek;
    string? namaProyek;
    string tanggal;
    int tahun;
    int urutan;
    string nomor;
    string? tujuan;
    string? perihal;
    string? keterangan;
    string? alasanPembatalan;
    boolean isDibatalkan;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/business/daftar-surat. Deliberately an OPEN record (no `{| |}`):
# `nomor`, `tahun` and `urutan` are computed entirely by the backend, so any of those sent by
# the client land in the rest fields and are silently ignored (the frontend never sends them).
#
# + kategoriSuratId - kategori_surat id (FK)
# + proyekId - optional proyek id
# + tanggal - letter date (YYYY-MM-DD)
# + tujuan - recipient
# + perihal - subject
# + keterangan - optional notes
public type NomorSuratCreateRequest record {
    int kategoriSuratId;
    int? proyekId?;
    string tanggal;
    string tujuan;
    string perihal;
    string? keterangan?;
};

# Request body for PUT /api/v1/business/daftar-surat/{id}. Open record for the same reason plus
# the immutability rule: only tanggal/proyekId/tujuan/perihal/keterangan are mutable, while
# kategoriSuratId/tahun/urutan/nomor are immutable after create — if the client sends any of the
# immutable fields, they land in the rest fields and are ignored rather than applied.
#
# + tanggal - new letter date (YYYY-MM-DD)
# + proyekId - new proyek id, or () to clear it
# + tujuan - new recipient
# + perihal - new subject
# + keterangan - new notes, or () to clear it
public type NomorSuratUpdateRequest record {
    string tanggal;
    int? proyekId?;
    string tujuan;
    string perihal;
    string? keterangan?;
};

# Result of a paginated nomor_surat list query: the page of items plus the pagination metadata.
#
# + items - the page of letters
# + pagination - pagination metadata
public type NomorSuratListResult record {|
    NomorSurat[] items;
    Pagination pagination;
|};

# Preview of the next letter number for the Tambah Surat form. Read-only: nothing is reserved in
# the database, so the value may change if another create commits first.
#
# + nomorPreview - the previewed next letter number
public type NomorSuratPreview record {|
    string nomorPreview;
|};

# Request body for DELETE /api/v1/business/daftar-surat/{id} (cancellation, not a physical delete).
# `alasanPembatalan` is mandatory for the audit trail — validated as non-blank and >= 5 characters
# by the service.
#
# + alasanPembatalan - mandatory cancellation reason
public type CancelNomorSuratRequest record {|
    string alasanPembatalan;
|};

# Response of a successful cancellation. Deliberately a minimal projection (not the full
# NomorSurat) — the cancel action only needs to confirm which letter was cancelled and the reason
# recorded, matching the API contract's example response exactly.
#
# + id - the cancelled letter's id
# + nomor - the cancelled letter's number
# + alasanPembatalan - the recorded cancellation reason
public type NomorSuratCancelled record {|
    int id;
    string nomor;
    string alasanPembatalan;
|};

# ===== Sales Unit — Proyek =====

# A proyek row as returned to the client, with joined display names (customer, industri, unit,
# PIC Sales, PMO, kontrak payung/biasa nomor) resolved in a single query — no N+1. `nilaiBersih`
# is DB-generated (`nilai_proyek - subkon`), always read-only. `kodeProyek`, `unitId` and `tahun`
# are immutable after create — `kodeProyek` is backend-generated FROM `unitId` + `tahun` (see
# proyek_repository), so allowing either to change afterward would leave the code stale/wrong.
# Audit columns are optional: the list endpoint selects only core+joined fields, the detail
# endpoint also fills the audit fields.
#
# + id - primary key
# + kodeProyek - backend-generated project code (immutable)
# + customerId - the owning customer
# + customerNama - joined customer name
# + industriId - the customer's industry sector
# + industriNama - joined industry name
# + unitId - the owning unit (immutable — embedded in kodeProyek)
# + unitNama - joined unit name
# + kontrakPayungId - optional linked kontrak payung id
# + noKontrakPayung - joined kontrak payung number (null if none)
# + kontrakBiasaId - optional linked kontrak biasa id
# + noKontrakBiasa - joined kontrak biasa number (null if none)
# + namaProyek - project name
# + departemen - optional department label
# + nilaiProyek - total project value
# + subkon - subcontractor portion
# + nilaiBersih - DB-generated net value (nilaiProyek - subkon)
# + picSalesId - the PIC Sales karyawan id
# + picSalesNama - joined PIC Sales name
# + pmoId - optional PMO karyawan id
# + pmoNama - joined PMO name (null if none)
# + noKontrak - optional contract number
# + tanggalKontrak - optional contract date (YYYY-MM-DD)
# + tanggalBast - optional BAST date (YYYY-MM-DD)
# + tanggalMulai - optional start date (YYYY-MM-DD)
# + tanggalDeal - date the proyek reached DEAL_KONTRAK (backend-set)
# + targetSelesai - optional target completion date (YYYY-MM-DD)
# + keteranganPembayaran - optional payment notes
# + status - the current proyek status
# + tahun - the numbering year (immutable — embedded in kodeProyek)
# + createdAt - when the row was created (detail only)
# + updatedAt - when the row was last updated (detail only, null if never)
# + createdBy - the `sub` claim of the creator (detail only)
# + updatedBy - the `sub` claim of the last updater (detail only, null if never)
public type Proyek record {|
    int id;
    string kodeProyek;
    int customerId;
    string customerNama;
    int industriId;
    string industriNama;
    int unitId;
    string unitNama;
    int? kontrakPayungId;
    string? noKontrakPayung;
    int? kontrakBiasaId;
    string? noKontrakBiasa;
    string namaProyek;
    string? departemen;
    decimal nilaiProyek;
    decimal subkon;
    decimal nilaiBersih;
    int picSalesId;
    string picSalesNama;
    int? pmoId;
    string? pmoNama;
    string? noKontrak;
    string? tanggalKontrak;
    string? tanggalBast;
    string? tanggalMulai;
    string? tanggalDeal;
    string? targetSelesai;
    string? keteranganPembayaran;
    string status;
    int tahun;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/business/proyek. Deliberately an OPEN record (no `{| |}`):
# `kodeProyek` is fully server-generated (from `unit.kode_unit` + `tahun`, mirrors nomor_surat's
# `nomor` generation) so any value the client sends for it is silently ignored. `status` defaults
# to "INFO_PELUANG" and `tahun` defaults to the current year when omitted. `tanggalDeal` is never
# accepted from the client — it's set by the backend only when status is/becomes "DEAL_KONTRAK"
# (see proyek_service).
#
# + customerId - the owning customer
# + industriId - the customer's industry sector
# + unitId - the owning unit (embedded in the generated kodeProyek)
# + kontrakPayungId - optional linked kontrak payung id
# + kontrakBiasaId - optional linked kontrak biasa id
# + namaProyek - project name
# + departemen - optional department label
# + nilaiProyek - total project value
# + subkon - optional subcontractor portion (defaults to 0)
# + picSalesId - the PIC Sales karyawan id
# + pmoId - optional PMO karyawan id
# + noKontrak - optional contract number
# + tanggalKontrak - optional contract date (YYYY-MM-DD)
# + tanggalBast - optional BAST date (YYYY-MM-DD)
# + tanggalMulai - optional start date (YYYY-MM-DD)
# + targetSelesai - optional target completion date (YYYY-MM-DD)
# + keteranganPembayaran - optional payment notes
# + status - optional initial status (defaults to INFO_PELUANG)
# + tahun - optional numbering year (defaults to current year)
public type ProyekCreateRequest record {
    int customerId;
    int industriId;
    int unitId;
    int? kontrakPayungId?;
    int? kontrakBiasaId?;
    string namaProyek;
    string? departemen?;
    decimal nilaiProyek;
    decimal subkon?;
    int picSalesId;
    int? pmoId?;
    string? noKontrak?;
    string? tanggalKontrak?;
    string? tanggalBast?;
    string? tanggalMulai?;
    string? targetSelesai?;
    string? keteranganPembayaran?;
    string status?;
    int tahun?;
};

# Request body for PUT /api/v1/business/proyek/{id}. Open record for the same reason as create:
# `kodeProyek`/`unitId`/`tahun` are immutable after create (silently ignored if sent). Changing
# `status` writes a `log_status` row and, when transitioning into "DEAL_KONTRAK" for the first
# time, auto-sets `tanggalDeal` (see proyek_service:updateProyek). `statusKomentar` is optional
# free text recorded on that `log_status` row — ignored when `status` is unchanged.
#
# + customerId - the owning customer
# + industriId - the customer's industry sector
# + kontrakPayungId - optional linked kontrak payung id
# + kontrakBiasaId - optional linked kontrak biasa id
# + namaProyek - project name
# + departemen - optional department label
# + nilaiProyek - total project value
# + subkon - subcontractor portion
# + picSalesId - the PIC Sales karyawan id
# + pmoId - optional PMO karyawan id
# + noKontrak - optional contract number
# + tanggalKontrak - optional contract date (YYYY-MM-DD)
# + tanggalBast - optional BAST date (YYYY-MM-DD)
# + tanggalMulai - optional start date (YYYY-MM-DD)
# + targetSelesai - optional target completion date (YYYY-MM-DD)
# + keteranganPembayaran - optional payment notes
# + status - the new status
# + statusKomentar - optional note recorded on the log_status row when status changes
public type ProyekUpdateRequest record {
    int customerId;
    int industriId;
    int? kontrakPayungId?;
    int? kontrakBiasaId?;
    string namaProyek;
    string? departemen?;
    decimal nilaiProyek;
    decimal subkon;
    int picSalesId;
    int? pmoId?;
    string? noKontrak?;
    string? tanggalKontrak?;
    string? tanggalBast?;
    string? tanggalMulai?;
    string? targetSelesai?;
    string? keteranganPembayaran?;
    string status;
    string? statusKomentar?;
};

# Result of a paginated proyek list query: the page of items plus pagination metadata.
#
# + items - the page of proyek
# + pagination - pagination metadata
public type ProyekListResult record {|
    Proyek[] items;
    Pagination pagination;
|};

# A recorded status transition for a proyek (`log_status`), returned by
# GET /api/v1/business/proyek/{id}/log-status. Read-only from the API's perspective — a row is
# only ever written by proyek_service, once at creation (the initial status) and again every time
# `status` actually changes via update; never directly writable through the API.
#
# + id - primary key
# + proyekId - the proyek this transition belongs to
# + status - the status as of this entry
# + komentar - optional free-text note attached to the transition
# + tanggal - the date this status took effect (YYYY-MM-DD)
# + createdAt - when this log row was written
# + createdBy - the `sub` claim of whoever triggered the transition
public type ProyekLogStatus record {|
    int id;
    int proyekId;
    string status;
    string? komentar;
    string tanggal;
    string createdAt;
    string createdBy;
|};

# A single proyek option for the "Project Tujuan" dropdown on the Tambah Surat form. Carries only
# the id + display fields — a lighter projection than the full `Proyek` type above, since the
# dropdown never needs anything beyond id/kode/nama.
#
# + id - proyek id
# + kodeProyek - proyek code
# + namaProyek - proyek name
public type ProyekDropdownItem record {|
    int id;
    string kodeProyek;
    string namaProyek;
|};

# ===== Sales Unit — Unit Share (pembagian nilai proyek antar unit) =====

# A unit_share row as returned to the client: how much of a proyek's value is attributed to a
# given unit. `unitNama` is joined in a single query (no N+1). `nilaiShare` is the absolute value
# allotted to the unit; `persentase` is an optional stored percentage (0..100, purely informational
# — the DB does not derive one from the other). Audit columns are optional (filled by list/detail).
#
# + id - primary key
# + proyekId - the proyek this share belongs to
# + unitId - the unit receiving the share
# + unitNama - joined unit name
# + nilaiShare - absolute value allotted to the unit
# + persentase - optional stored percentage (0..100)
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type UnitShare record {|
    int id;
    int proyekId;
    int unitId;
    string unitNama;
    decimal nilaiShare;
    decimal? persentase;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/business/proyek/{proyekId}/unit-share. `proyekId` comes from the
# path, never the body. Each (proyek, unit) pair is unique — attaching the same unit twice is a
# CONFLICT. The sum of all a proyek's non-deleted shares may not exceed its `nilai_proyek`.
#
# + unitId - the unit to allot a share to
# + nilaiShare - absolute value allotted (must be > 0)
# + persentase - optional stored percentage (0..100)
public type UnitShareCreateRequest record {
    int unitId;
    decimal nilaiShare;
    decimal? persentase?;
};

# Request body for PUT /api/v1/business/proyek/{proyekId}/unit-share/{id}. Same shape/rules as
# create — `unitId` may be changed, but the resulting (proyek, unit) pair must still be unique and
# the total share must still fit within the proyek's `nilai_proyek`.
#
# + unitId - the unit to allot a share to
# + nilaiShare - absolute value allotted (must be > 0)
# + persentase - optional stored percentage (0..100)
public type UnitShareUpdateRequest record {
    int unitId;
    decimal nilaiShare;
    decimal? persentase?;
};

# ===== Sales Unit — Team Member (penugasan karyawan ke proyek per periode) =====

# A team_member row as returned to the client: a karyawan assigned to a proyek in a given project
# role for a period. `karyawanNama`/`roleNama` are joined in a single query (no N+1).
# `undanganStatus` (invitation-email state) is backend-controlled — it starts "BELUM_DIKIRIM" and
# is never set from the CRUD payload (the email-sending flow is a separate, not-yet-built concern);
# `undanganSentAt`/`undanganSentBy` are likewise backend-only. Audit columns are optional.
#
# + id - primary key
# + proyekId - the proyek this assignment belongs to
# + karyawanId - the assigned karyawan
# + karyawanNama - joined karyawan name
# + roleId - the project role (project_role_master)
# + roleNama - joined project-role name
# + tglMulai - assignment start date (YYYY-MM-DD), null if open
# + tglSelesai - assignment end date (YYYY-MM-DD), null if open-ended
# + bobot - optional effort weight (0..100)
# + keterangan - optional free-text note
# + undanganStatus - invitation-email state (BELUM_DIKIRIM/TERKIRIM/GAGAL), backend-controlled
# + undanganSentAt - when the invitation email was sent (null until sent)
# + undanganSentBy - who triggered the invitation email (null until sent)
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type TeamMember record {|
    int id;
    int proyekId;
    int karyawanId;
    string karyawanNama;
    int roleId;
    string roleNama;
    string? tglMulai;
    string? tglSelesai;
    decimal? bobot;
    string? keterangan;
    string undanganStatus;
    string? undanganSentAt;
    string? undanganSentBy;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/business/proyek/{proyekId}/team-member. `proyekId` comes from the
# path. `undanganStatus`/`undanganSentAt`/`undanganSentBy` are never accepted from the client. The
# same karyawan may not be assigned twice with the same `tglMulai` (unique per proyek); `tglSelesai`
# (when both are set) must not precede `tglMulai`.
#
# + karyawanId - the karyawan to assign
# + roleId - the project role (project_role_master)
# + tglMulai - optional assignment start date (YYYY-MM-DD)
# + tglSelesai - optional assignment end date (YYYY-MM-DD)
# + bobot - optional effort weight (0..100)
# + keterangan - optional free-text note
public type TeamMemberCreateRequest record {
    int karyawanId;
    int roleId;
    string? tglMulai?;
    string? tglSelesai?;
    decimal? bobot?;
    string? keterangan?;
};

# Request body for PUT /api/v1/business/proyek/{proyekId}/team-member/{id}. Same shape/rules as
# create. Invitation-email fields remain backend-controlled and are ignored if sent.
#
# + karyawanId - the karyawan to assign
# + roleId - the project role (project_role_master)
# + tglMulai - optional assignment start date (YYYY-MM-DD)
# + tglSelesai - optional assignment end date (YYYY-MM-DD)
# + bobot - optional effort weight (0..100)
# + keterangan - optional free-text note
public type TeamMemberUpdateRequest record {
    int karyawanId;
    int roleId;
    string? tglMulai?;
    string? tglSelesai?;
    decimal? bobot?;
    string? keterangan?;
};

# ===== Sales Unit — Proyek Tags (many-to-many proyek <-> tags) =====

# A tag currently attached to a proyek, as returned by GET /api/v1/business/proyek/{proyekId}/tags.
# The `proyek_tags` junction carries only the two ids, so the tag's display fields are joined from
# `tags`.
#
# + tagsId - the tag id
# + kode - the tag code
# + nama - the tag name
# + unitId - the tag's owning unit id, or null for a global tag
public type ProyekTag record {|
    int tagsId;
    string kode;
    string nama;
    int? unitId;
|};

# Request body for PUT /api/v1/business/proyek/{proyekId}/tags — replaces the proyek's entire tag
# set in one atomic operation. Duplicate ids in the list are collapsed; an empty list clears all
# tags. Every id must reference an existing, non-deleted tag.
#
# + tagIds - the complete desired set of tag ids for the proyek
public type ProyekTagsUpdateRequest record {|
    int[] tagIds;
|};

# ===== Sales Unit — Kontrak Payung =====

# One price line of a kontrak payung: the agreed price for a given project role, as returned inside
# a kontrak payung detail. `roleNama` is joined from `project_role_master` (no N+1). The
# `kontrak_payung_harga_role` table has no soft-delete/update-audit columns — the whole set is
# managed together with the parent contract (replaced wholesale on update).
#
# + id - primary key
# + kontrakPayungId - the owning kontrak payung id
# + roleId - the project role (project_role_master)
# + roleNama - joined project-role name
# + tipeHarga - price basis: "PER_BULAN" or "PER_PROJECT"
# + nilai - the agreed price
# + keterangan - optional note
public type KontrakPayungHargaRole record {|
    int id;
    int kontrakPayungId;
    int roleId;
    string roleNama;
    string tipeHarga;
    decimal nilai;
    string? keterangan;
|};

# A kontrak payung row as returned to the client. `customerNama` is joined in a single query (no
# N+1). `hargaRole` is only populated on the detail endpoint (the list projection omits it). Audit
# columns are optional (filled by list/detail).
#
# + id - primary key
# + customerId - the owning customer
# + customerNama - joined customer name
# + noKontrakPayung - the unique contract number
# + namaKontrak - the contract name
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + tanggalMulai - the coverage start date (YYYY-MM-DD)
# + tanggalSelesai - the coverage end date (YYYY-MM-DD)
# + hargaRole - the per-role price lines (detail endpoint only)
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type KontrakPayung record {|
    int id;
    int customerId;
    string customerNama;
    string noKontrakPayung;
    string namaKontrak;
    string tanggalKontrak;
    string tanggalMulai;
    string tanggalSelesai;
    KontrakPayungHargaRole[] hargaRole?;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# One price line as accepted in a create/update payload — the server assigns the id and links it to
# the parent contract, so neither is taken from the client.
#
# + roleId - the project role (project_role_master)
# + tipeHarga - price basis: "PER_BULAN" or "PER_PROJECT"
# + nilai - the agreed price (must be > 0)
# + keterangan - optional note (max 255 chars)
public type KontrakPayungHargaRoleInput record {
    int roleId;
    string tipeHarga;
    decimal nilai;
    string? keterangan?;
};

# Request body for POST /api/v1/business/kontrak-payung. `noKontrakPayung` is unique. When
# `hargaRole` is present its lines are inserted atomically with the contract; when omitted the
# contract is created with no price lines. `tanggalSelesai` may not precede `tanggalMulai`.
#
# + customerId - the owning customer
# + noKontrakPayung - the unique contract number (max 50 chars)
# + namaKontrak - the contract name (max 150 chars)
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + tanggalMulai - the coverage start date (YYYY-MM-DD)
# + tanggalSelesai - the coverage end date (YYYY-MM-DD)
# + hargaRole - optional per-role price lines to attach
public type KontrakPayungCreateRequest record {
    int customerId;
    string noKontrakPayung;
    string namaKontrak;
    string tanggalKontrak;
    string tanggalMulai;
    string tanggalSelesai;
    KontrakPayungHargaRoleInput[] hargaRole?;
};

# Request body for PUT /api/v1/business/kontrak-payung/{id}. Same fields as create. `hargaRole` has
# replace-or-leave semantics: when the field is PRESENT (including an empty array) the contract's
# entire price-line set is replaced with it; when the field is OMITTED the existing price lines are
# left untouched.
#
# + customerId - the owning customer
# + noKontrakPayung - the unique contract number (max 50 chars)
# + namaKontrak - the contract name (max 150 chars)
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + tanggalMulai - the coverage start date (YYYY-MM-DD)
# + tanggalSelesai - the coverage end date (YYYY-MM-DD)
# + hargaRole - optional replacement set of per-role price lines (omit to leave unchanged)
public type KontrakPayungUpdateRequest record {
    int customerId;
    string noKontrakPayung;
    string namaKontrak;
    string tanggalKontrak;
    string tanggalMulai;
    string tanggalSelesai;
    KontrakPayungHargaRoleInput[] hargaRole?;
};

# Result of a paginated kontrak payung list query: the page of items plus pagination metadata.
#
# + items - the page of kontrak payung
# + pagination - pagination metadata
public type KontrakPayungListResult record {|
    KontrakPayung[] items;
    Pagination pagination;
|};

# A single kontrak payung option for the dropdown on the Proyek form. Carries only id + display
# fields — a lighter projection than the full `KontrakPayung` type.
#
# + id - kontrak payung id
# + noKontrakPayung - contract number
# + namaKontrak - contract name
public type KontrakPayungDropdownItem record {|
    int id;
    string noKontrakPayung;
    string namaKontrak;
|};

# ===== Sales Unit — Kontrak Biasa =====

# A kontrak biasa row as returned to the client. `customerNama` and the optional parent
# `noKontrakPayung` are joined in a single query (no N+1). A kontrak biasa may stand on its own
# (`kontrakPayungId` null) or hang under a kontrak payung — when linked, both must belong to the
# same customer (enforced by the service; the DB has no FK for that). `nilai` is optional (a
# contract whose value isn't recorded yet). Audit columns are optional (filled by list/detail).
#
# + id - primary key
# + kontrakPayungId - optional parent kontrak payung id (null = standalone)
# + noKontrakPayung - joined parent contract number (null when standalone)
# + customerId - the owning customer
# + customerNama - joined customer name
# + noKontrakBiasa - the unique contract number
# + namaKontrak - the contract name
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + nilai - optional contract value
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type KontrakBiasa record {|
    int id;
    int? kontrakPayungId;
    string? noKontrakPayung;
    int customerId;
    string customerNama;
    string noKontrakBiasa;
    string namaKontrak;
    string tanggalKontrak;
    decimal? nilai;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/business/kontrak-biasa. `noKontrakBiasa` is unique. When
# `kontrakPayungId` is present the referenced kontrak payung must exist and belong to the same
# `customerId`.
#
# + kontrakPayungId - optional parent kontrak payung id
# + customerId - the owning customer
# + noKontrakBiasa - the unique contract number (max 50 chars)
# + namaKontrak - the contract name (max 150 chars)
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + nilai - optional contract value (must be > 0 when present)
public type KontrakBiasaCreateRequest record {
    int? kontrakPayungId?;
    int customerId;
    string noKontrakBiasa;
    string namaKontrak;
    string tanggalKontrak;
    decimal? nilai?;
};

# Request body for PUT /api/v1/business/kontrak-biasa/{id}. Full-replace semantics matching the
# Proyek convention: an omitted optional field (`kontrakPayungId`, `nilai`) clears that column.
#
# + kontrakPayungId - optional parent kontrak payung id (omit to clear)
# + customerId - the owning customer
# + noKontrakBiasa - the unique contract number (max 50 chars)
# + namaKontrak - the contract name (max 150 chars)
# + tanggalKontrak - the contract date (YYYY-MM-DD)
# + nilai - optional contract value (omit to clear; must be > 0 when present)
public type KontrakBiasaUpdateRequest record {
    int? kontrakPayungId?;
    int customerId;
    string noKontrakBiasa;
    string namaKontrak;
    string tanggalKontrak;
    decimal? nilai?;
};

# Result of a paginated kontrak biasa list query: the page of items plus pagination metadata.
#
# + items - the page of kontrak biasa
# + pagination - pagination metadata
public type KontrakBiasaListResult record {|
    KontrakBiasa[] items;
    Pagination pagination;
|};

# A single kontrak biasa option for the dropdown on the Proyek form. Carries only id + display
# fields — a lighter projection than the full `KontrakBiasa` type.
#
# + id - kontrak biasa id
# + noKontrakBiasa - contract number
# + namaKontrak - contract name
public type KontrakBiasaDropdownItem record {|
    int id;
    string noKontrakBiasa;
    string namaKontrak;
|};

# ===== Sales Unit — Target Revenue Unit (CRUD, per unit per tahun) =====

# A target_revenue_unit row as returned to the client: a unit's revenue target for a year, split
# across the four triwulan (quarters). `unitNama` is joined (no N+1); `targetTotal` is the computed
# sum of the four quarters. This table has NO `is_deleted` column, so deletes are physical.
#
# + id - primary key
# + unitId - the unit this target belongs to
# + unitNama - joined unit name
# + tahun - the target year
# + targetTw1 - revenue target for quarter 1
# + targetTw2 - revenue target for quarter 2
# + targetTw3 - revenue target for quarter 3
# + targetTw4 - revenue target for quarter 4
# + targetTotal - computed sum of the four quarter targets
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type TargetRevenueUnit record {|
    int id;
    int unitId;
    string unitNama;
    int tahun;
    decimal targetTw1;
    decimal targetTw2;
    decimal targetTw3;
    decimal targetTw4;
    decimal targetTotal;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/business/target-revenue-unit. Each (unit, tahun) pair is unique.
# Any omitted quarter target defaults to 0. All targets must be non-negative.
#
# + unitId - the unit to set a target for
# + tahun - the target year
# + targetTw1 - optional quarter-1 target (defaults to 0)
# + targetTw2 - optional quarter-2 target (defaults to 0)
# + targetTw3 - optional quarter-3 target (defaults to 0)
# + targetTw4 - optional quarter-4 target (defaults to 0)
public type TargetRevenueUnitCreateRequest record {
    int unitId;
    int tahun;
    decimal targetTw1?;
    decimal targetTw2?;
    decimal targetTw3?;
    decimal targetTw4?;
};

# Request body for PUT /api/v1/business/target-revenue-unit/{id}. Same shape/rules as create; the
# resulting (unit, tahun) pair must still be unique. Omitted quarter targets default to 0.
#
# + unitId - the unit to set a target for
# + tahun - the target year
# + targetTw1 - optional quarter-1 target (defaults to 0)
# + targetTw2 - optional quarter-2 target (defaults to 0)
# + targetTw3 - optional quarter-3 target (defaults to 0)
# + targetTw4 - optional quarter-4 target (defaults to 0)
public type TargetRevenueUnitUpdateRequest record {
    int unitId;
    int tahun;
    decimal targetTw1?;
    decimal targetTw2?;
    decimal targetTw3?;
    decimal targetTw4?;
};

# Result of a paginated target revenue unit list query: the page of items plus pagination metadata.
#
# + items - the page of target revenue unit rows
# + pagination - pagination metadata
public type TargetRevenueUnitListResult record {|
    TargetRevenueUnit[] items;
    Pagination pagination;
|};

# ===== Sales Unit — Revenue Unit reports (target vs realisasi) =====

# One row of the Revenue Unit report (GET /api/v1/business/revenue-unit): a unit's revenue target vs
# actual realisasi for a year, broken down by triwulan plus totals and achievement. `target*` come
# from `target_revenue_unit`; `realisasi*` are cash-basis actuals from the `v_realisasi_revenue_tw`
# view (sum of PARSIAL/FINAL `pencairan_tagihan` grouped by the proyek's unit and the disbursement
# quarter). `pencapaianPersen` = realisasiTotal / targetTotal * 100 (0 when the target is 0).
#
# + unitId - the unit
# + unitNama - joined unit name
# + tahun - the report year
# + targetTw1 - quarter-1 target
# + targetTw2 - quarter-2 target
# + targetTw3 - quarter-3 target
# + targetTw4 - quarter-4 target
# + targetTotal - sum of the four quarter targets
# + realisasiTw1 - quarter-1 actual revenue
# + realisasiTw2 - quarter-2 actual revenue
# + realisasiTw3 - quarter-3 actual revenue
# + realisasiTw4 - quarter-4 actual revenue
# + realisasiTotal - sum of the four quarter actuals
# + pencapaianPersen - realisasiTotal / targetTotal * 100 (0 when target is 0)
public type RevenueUnitRow record {|
    int unitId;
    string unitNama;
    int tahun;
    decimal targetTw1;
    decimal targetTw2;
    decimal targetTw3;
    decimal targetTw4;
    decimal targetTotal;
    decimal realisasiTw1;
    decimal realisasiTw2;
    decimal realisasiTw3;
    decimal realisasiTw4;
    decimal realisasiTotal;
    decimal pencapaianPersen;
|};

# One row of the Revenue Unit per-Triwulan report (GET /api/v1/business/revenue-unit/tw): a unit's
# target vs realisasi for a single quarter of a year.
#
# + unitId - the unit
# + unitNama - joined unit name
# + tahun - the report year
# + triwulan - the quarter (1..4)
# + target - the unit's target for that quarter
# + realisasi - the unit's actual revenue for that quarter
# + pencapaianPersen - realisasi / target * 100 (0 when target is 0)
public type RevenueUnitTwRow record {|
    int unitId;
    string unitNama;
    int tahun;
    int triwulan;
    decimal target;
    decimal realisasi;
    decimal pencapaianPersen;
|};

# One point of the Revenue Unit chart: aggregated target vs realisasi for a single quarter.
#
# + triwulan - the quarter (1..4)
# + label - the quarter label ("TW1".."TW4")
# + target - total target for the quarter (one unit, or summed across all units)
# + realisasi - total actual revenue for the quarter (one unit, or summed across all units)
public type RevenueUnitChartPoint record {|
    int triwulan;
    string label;
    decimal target;
    decimal realisasi;
|};

# The Revenue Unit chart (GET /api/v1/business/revenue-unit/chart): four quarter points of target vs
# realisasi for a year, either for a single unit (when `unitId` is given) or aggregated across all
# units. Always carries exactly four points (TW1..TW4), zero-filled where there's no data.
#
# + tahun - the chart year
# + unitId - the single unit the chart is scoped to, or null when aggregated across all units
# + unitNama - the single unit's name, or null when aggregated
# + points - the four quarter points (TW1..TW4)
public type RevenueUnitChart record {|
    int tahun;
    int? unitId;
    string? unitNama;
    RevenueUnitChartPoint[] points;
|};

# ===== Profil Saya (self-service profile) =====

# Request body for PUT /api/v1/profil-saya. Only contact info is self-editable — nik/nama/jabatan/
# unit/status/subjectId stay HR-managed via the Karyawan master module (`karyawan_service`); sending
# them here would have no effect since they simply aren't part of this request shape.
#
# + email - new employee email
# + noHp - new phone number, or () to clear it
public type ProfilSayaUpdateRequest record {|
    string email;
    string? noHp?;
|};

# ===== Notifikasi (self-service notification inbox) =====

# A notification row as returned to the client. Scoped implicitly to the caller — the recipient
# (`recipient_karyawan_id`) is resolved server-side from the access token and never appears in the
# response or request shape. `refTable`/`refId` optionally point at the record the notification is
# about (e.g. "proyek", 42); `linkLabel` is an optional display label for a frontend deep link.
#
# + id - primary key
# + kategori - PENUGASAN / STATUS / SISTEM
# + judul - notification title
# + pesan - notification body
# + refTable - optional name of the table the notification references
# + refId - optional id of the row the notification references
# + linkLabel - optional display label for a frontend deep link
# + isRead - whether the recipient has read this notification
# + readAt - when the recipient read it, or () if unread
# + createdAt - when the notification was created
public type Notification record {|
    int id;
    string kategori;
    string judul;
    string pesan;
    string? refTable;
    int? refId;
    string? linkLabel;
    boolean isRead;
    string? readAt;
    string createdAt;
|};

# Result of a paginated notification list query: the page of items plus pagination metadata.
#
# + items - the page of notifications
# + pagination - pagination metadata
public type NotificationListResult record {|
    Notification[] items;
    Pagination pagination;
|};

# Response of GET /api/v1/notifikasi/unread-count.
#
# + unreadCount - number of unread notifications for the caller
public type NotificationUnreadCount record {|
    int unreadCount;
|};

# ===== Audit Log (read-only, append-only) =====

# An audit_log row as returned to the client. Rows are written internally by other services (e.g.
# `nomor_surat_service` on cancel, via `repositories:insertAuditLog`) — this type only ever backs
# read responses, never a request body. `perubahan` is decoded back from its JSON-encoded text
# column into structured `json` (`()` when the row has none recorded).
#
# + id - primary key
# + tableName - the audited table's name (e.g. "nomor_surat")
# + recordId - the audited row's id (stored as text in the DB)
# + aksi - CREATE / UPDATE / DELETE
# + aktor - the `sub` claim of whoever made the change
# + ipAddress - optional caller IP (not yet populated anywhere in this codebase)
# + perubahan - the recorded change detail (`{"column": {"old": ..., "new": ...}, ...}`), or () if none
# + waktu - when the change happened
public type AuditLogEntry record {|
    int id;
    string tableName;
    string recordId;
    string aksi;
    string aktor;
    string? ipAddress;
    json perubahan;
    string waktu;
|};

# Result of a paginated audit log list query: the page of entries plus pagination metadata.
#
# + items - the page of audit log entries
# + pagination - pagination metadata
public type AuditLogListResult record {|
    AuditLogEntry[] items;
    Pagination pagination;
|};

# ===== Konfigurasi Sistem (sys_config, key-value global) =====

# A sys_config row as returned to the client. The table's primary key is `key` itself (no numeric
# id) — a fixed, seeded registry of settings actually read by name throughout the codebase (e.g.
# `prefix_kode_proyek`, `prefix_nomor_surat`). `value`/`updatedAt`/`updatedBy` are nullable: a few
# rows (`last_sync_at`, `last_sync_status`) start out NULL by design, and none has ever been updated
# yet on a fresh install.
#
# + key - the setting's unique key (primary key)
# + value - the setting's current value, or () if unset
# + deskripsi - human-readable description (read-only from the API — see `SysConfigUpdateRequest`)
# + updatedAt - when the value was last changed, or () if never
# + updatedBy - the `sub` claim of the last updater, or () if never
public type SysConfig record {|
    string 'key;
    string? value;
    string? deskripsi;
    string? updatedAt;
    string? updatedBy;
|};

# Request body for PUT /api/v1/konfigurasi-sistem/{key}. Only `value` is editable — `deskripsi` is a
# system-defined label and `key` never changes (it's the identity of the row, taken from the path).
# Send `null` to clear the value (valid for nullable settings like `last_sync_at`).
#
# + value - the new value, or () to clear it
public type SysConfigUpdateRequest record {|
    string? value;
|};

# ===== Manajemen User (read-only WSO2 IS user cache) =====

# A user_cache row as returned to the client, LEFT JOINed to `karyawan` (via `subject_id`) so the
# admin screen can show which karyawan a WSO2 IS identity is linked to, if any. READ-ONLY: per the
# schema's own implementation note #2, user write operations (create/disable/PATCH the
# `swaportal_role_id` custom attribute) go through WSO2's SCIM2 API with app-level credentials, not
# through this database — this codebase has no SCIM2 client yet, and `user_cache` itself is meant to
# be populated by a periodic reconciliation job (`sys_config.jadwal_reconciliation`) that is a
# separate, not-yet-built concern. This module only ever reads whatever is already in the table.
#
# + subjectId - the WSO2 IS user's subject id (primary key)
# + nama - cached display name, or () if not yet synced
# + email - cached email, or () if not yet synced
# + status - cached account status, or () if not yet synced
# + syncSource - where this row was synced from (defaults to "WSO2_IS")
# + lastSyncedAt - when this row was last synced, or () if never
# + karyawanId - the linked karyawan's id, or () if no karyawan links to this subject
# + karyawanNama - the linked karyawan's name, or () if no karyawan links to this subject
public type UserCacheItem record {|
    string subjectId;
    string? nama;
    string? email;
    string? status;
    string? syncSource;
    string? lastSyncedAt;
    int? karyawanId;
    string? karyawanNama;
|};

# Result of a paginated user cache list query: the page of items plus pagination metadata.
#
# + items - the page of user cache rows
# + pagination - pagination metadata
public type UserCacheListResult record {|
    UserCacheItem[] items;
    Pagination pagination;
|};

# ===== Finansial — Tagihan =====

# A tagihan (invoice/billing) row as returned to the client, with the joined proyek display fields
# and the computed running total of its realized (PARSIAL/FINAL) pencairan. `statusAktif` tracks the
# billing lifecycle (RENCANA→BAST→KIRIM_TAGIHAN→LUNAS, or PELUANG/TIDAK_TERTAGIH) — every change is
# also logged to `status_tagihan` (see `TagihanStatusHistory`). `nilaiDpp`/`ppn`/`pph` are optional
# tax breakdown fields. Audit columns are optional (filled by list/detail).
#
# + id - primary key
# + proyekId - the proyek this tagihan belongs to
# + proyekKode - joined proyek kode_proyek
# + proyekNama - joined proyek nama_proyek
# + tanggalTagihan - the invoice date (YYYY-MM-DD)
# + noTagihan - the unique invoice number
# + keterangan - optional note
# + statusAktif - billing lifecycle status
# + nilaiTagihan - the invoiced amount
# + nilaiDpp - optional taxable base (DPP)
# + ppn - optional VAT amount
# + pph - optional withholding tax amount
# + totalPencairan - computed sum of this tagihan's non-cancelled (PARSIAL/FINAL) pencairan
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type Tagihan record {|
    int id;
    int proyekId;
    string proyekKode;
    string proyekNama;
    string tanggalTagihan;
    string noTagihan;
    string? keterangan;
    string statusAktif;
    decimal nilaiTagihan;
    decimal? nilaiDpp;
    decimal? ppn;
    decimal? pph;
    decimal totalPencairan;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/finance/tagihan. `noTagihan` is unique. `statusAktif` defaults to
# "RENCANA" when omitted; the initial status is always logged to `status_tagihan`.
#
# + proyekId - the proyek this tagihan belongs to
# + tanggalTagihan - the invoice date (YYYY-MM-DD)
# + noTagihan - the unique invoice number (max 50 chars)
# + keterangan - optional note
# + statusAktif - optional initial billing status (defaults to RENCANA)
# + nilaiTagihan - the invoiced amount (must be > 0)
# + nilaiDpp - optional taxable base (DPP)
# + ppn - optional VAT amount
# + pph - optional withholding tax amount
public type TagihanCreateRequest record {
    int proyekId;
    string tanggalTagihan;
    string noTagihan;
    string? keterangan?;
    string statusAktif?;
    decimal nilaiTagihan;
    decimal? nilaiDpp?;
    decimal? ppn?;
    decimal? pph?;
};

# Request body for PUT /api/v1/finance/tagihan/{id}. Changing `statusAktif` logs a `status_tagihan`
# row; `statusKomentar` is the optional note recorded on that log row (ignored when the status is
# unchanged).
#
# + proyekId - the proyek this tagihan belongs to
# + tanggalTagihan - the invoice date (YYYY-MM-DD)
# + noTagihan - the unique invoice number (max 50 chars)
# + keterangan - optional note
# + statusAktif - the billing status
# + statusKomentar - optional note recorded on the status_tagihan log row when status changes
# + nilaiTagihan - the invoiced amount (must be > 0)
# + nilaiDpp - optional taxable base (DPP)
# + ppn - optional VAT amount
# + pph - optional withholding tax amount
public type TagihanUpdateRequest record {
    int proyekId;
    string tanggalTagihan;
    string noTagihan;
    string? keterangan?;
    string statusAktif;
    string? statusKomentar?;
    decimal nilaiTagihan;
    decimal? nilaiDpp?;
    decimal? ppn?;
    decimal? pph?;
};

# Result of a paginated tagihan list query: the page of items plus pagination metadata.
#
# + items - the page of tagihan
# + pagination - pagination metadata
public type TagihanListResult record {|
    Tagihan[] items;
    Pagination pagination;
|};

# A recorded status transition for a tagihan (`status_tagihan`), returned by
# GET /api/v1/finance/tagihan/{id}/status-history. Read-only: written by tagihan_service, once at
# creation and again whenever `statusAktif` actually changes.
#
# + id - primary key
# + tagihanId - the tagihan this transition belongs to
# + status - the status as of this entry
# + tanggal - the date this status took effect (YYYY-MM-DD)
# + keterangan - optional note attached to the transition
# + createdAt - when this log row was written
# + createdBy - the `sub` claim of whoever triggered the transition
public type TagihanStatusHistory record {|
    int id;
    int tagihanId;
    string status;
    string tanggal;
    string? keterangan;
    string createdAt;
    string createdBy;
|};

# ===== Finansial — Pencairan Tagihan =====

# A pencairan (disbursement / cash-in realization) of a tagihan, returned as a sub-resource of the
# tagihan. A tagihan may be disbursed in stages, so it can have several pencairan; `status` is
# PARSIAL / FINAL / DIBATALKAN, and only non-cancelled ones count toward the tagihan's realized
# total. This table has no update-audit columns (created only).
#
# + id - primary key
# + tagihanId - the tagihan this pencairan belongs to
# + tanggalPencairan - the disbursement date (YYYY-MM-DD)
# + nilai - the disbursed amount (> 0)
# + status - PARSIAL / FINAL / DIBATALKAN
# + keterangan - optional note
# + createdAt - when the row was created
# + createdBy - the `sub` claim of the creator
public type PencairanTagihan record {|
    int id;
    int tagihanId;
    string tanggalPencairan;
    decimal nilai;
    string status;
    string? keterangan;
    string createdAt?;
    string createdBy?;
|};

# Request body for POST /api/v1/finance/tagihan/{tagihanId}/pencairan. The sum of a tagihan's
# non-cancelled pencairan may not exceed its `nilaiTagihan`.
#
# + tanggalPencairan - the disbursement date (YYYY-MM-DD)
# + nilai - the disbursed amount (must be > 0)
# + status - PARSIAL / FINAL / DIBATALKAN
# + keterangan - optional note
public type PencairanCreateRequest record {
    string tanggalPencairan;
    decimal nilai;
    string status;
    string? keterangan?;
};

# Request body for PUT /api/v1/finance/tagihan/{tagihanId}/pencairan/{id}. Same shape/rules as create.
#
# + tanggalPencairan - the disbursement date (YYYY-MM-DD)
# + nilai - the disbursed amount (must be > 0)
# + status - PARSIAL / FINAL / DIBATALKAN
# + keterangan - optional note
public type PencairanUpdateRequest record {
    string tanggalPencairan;
    decimal nilai;
    string status;
    string? keterangan?;
};

# ===== Finansial — Pembayaran (cash-out tied to a proyek) =====

# A pembayaran (project-tied cash-out) row, with joined proyek + kategori display fields. Goes
# through an approval workflow: `status` is PENGAJUAN → APPROVED / REJECTED; a REJECTED row can be
# revised (edited), which resets it to PENGAJUAN. `approvedBy`/`approvedAt`/`catatanApproval` are
# filled by the approve/reject actions. Audit columns are optional.
#
# + id - primary key
# + proyekId - the proyek this payment is tied to
# + proyekKode - joined proyek kode_proyek
# + proyekNama - joined proyek nama_proyek
# + kategoriId - the kategori_finansial_keluar id
# + kategoriNama - joined kategori name
# + nilai - the payment amount (> 0)
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - the actual cash-out date, or () if not yet realized
# + keterangan - optional note
# + status - PENGAJUAN / APPROVED / REJECTED
# + approvedBy - the `sub` claim of the approver/rejecter, or () if still pending
# + approvedAt - when it was approved/rejected, or () if still pending
# + catatanApproval - optional approval/rejection note
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type Pembayaran record {|
    int id;
    int proyekId;
    string proyekKode;
    string proyekNama;
    int kategoriId;
    string kategoriNama;
    decimal nilai;
    string tanggalPengajuan;
    string? tanggalRealisasi;
    string? keterangan;
    string status;
    string? approvedBy;
    string? approvedAt;
    string? catatanApproval;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/finance/pembayaran. Always created with status PENGAJUAN.
#
# + proyekId - the proyek this payment is tied to
# + kategoriId - the kategori_finansial_keluar id
# + nilai - the payment amount (must be > 0)
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - optional actual cash-out date (YYYY-MM-DD)
# + keterangan - optional note
public type PembayaranCreateRequest record {
    int proyekId;
    int kategoriId;
    decimal nilai;
    string tanggalPengajuan;
    string? tanggalRealisasi?;
    string? keterangan?;
};

# Request body for PUT /api/v1/finance/pembayaran/{id}. Only editable while status is PENGAJUAN or
# REJECTED — editing a REJECTED row resets it to PENGAJUAN (schema implementation note #5). An
# APPROVED row is locked.
#
# + proyekId - the proyek this payment is tied to
# + kategoriId - the kategori_finansial_keluar id
# + nilai - the payment amount (must be > 0)
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - optional actual cash-out date (YYYY-MM-DD)
# + keterangan - optional note
public type PembayaranUpdateRequest record {
    int proyekId;
    int kategoriId;
    decimal nilai;
    string tanggalPengajuan;
    string? tanggalRealisasi?;
    string? keterangan?;
};

# Result of a paginated pembayaran list query: the page of items plus pagination metadata.
#
# + items - the page of pembayaran
# + pagination - pagination metadata
public type PembayaranListResult record {|
    Pembayaran[] items;
    Pagination pagination;
|};

# Request body for the approve action (PUT .../approve) on a pembayaran or pengeluaran. Optionally
# sets the realization date (when the cash actually goes out) and an approval note.
#
# + tanggalRealisasi - optional actual cash-out date to record on approval (YYYY-MM-DD)
# + catatan - optional approval note
public type ApproveRequest record {
    string? tanggalRealisasi?;
    string? catatan?;
};

# Request body for the reject action (PUT .../reject) on a pembayaran or pengeluaran.
#
# + catatan - optional rejection note
public type RejectRequest record {
    string? catatan?;
};

# ===== Finansial — Pengeluaran Perusahaan (cash-out, internal operational) =====

# A pengeluaran perusahaan (unit-tied internal cash-out) row, with joined unit + kategori display
# fields. Same approval workflow as Pembayaran (PENGAJUAN → APPROVED / REJECTED; REJECTED editable →
# resets to PENGAJUAN). Audit columns are optional.
#
# + id - primary key
# + unitId - the unit this expense belongs to
# + unitNama - joined unit name
# + kategoriId - the kategori_finansial_keluar id
# + kategoriNama - joined kategori name
# + nilai - the expense amount (> 0)
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - the actual cash-out date, or () if not yet realized
# + keterangan - optional note
# + status - PENGAJUAN / APPROVED / REJECTED
# + approvedBy - the `sub` claim of the approver/rejecter, or () if still pending
# + approvedAt - when it was approved/rejected, or () if still pending
# + catatanApproval - optional approval/rejection note
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type PengeluaranPerusahaan record {|
    int id;
    int unitId;
    string unitNama;
    int kategoriId;
    string kategoriNama;
    decimal nilai;
    string tanggalPengajuan;
    string? tanggalRealisasi;
    string? keterangan;
    string status;
    string? approvedBy;
    string? approvedAt;
    string? catatanApproval;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/finance/pengeluaran-perusahaan. Always created with status PENGAJUAN.
#
# + unitId - the unit this expense belongs to
# + kategoriId - the kategori_finansial_keluar id
# + nilai - the expense amount (must be > 0)
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - optional actual cash-out date (YYYY-MM-DD)
# + keterangan - optional note
public type PengeluaranCreateRequest record {
    int unitId;
    int kategoriId;
    decimal nilai;
    string tanggalPengajuan;
    string? tanggalRealisasi?;
    string? keterangan?;
};

# Request body for PUT /api/v1/finance/pengeluaran-perusahaan/{id}. Only editable while PENGAJUAN or
# REJECTED (editing a REJECTED row resets it to PENGAJUAN); an APPROVED row is locked.
#
# + unitId - the unit this expense belongs to
# + kategoriId - the kategori_finansial_keluar id
# + nilai - the expense amount (must be > 0)
# + tanggalPengajuan - the request date (YYYY-MM-DD)
# + tanggalRealisasi - optional actual cash-out date (YYYY-MM-DD)
# + keterangan - optional note
public type PengeluaranUpdateRequest record {
    int unitId;
    int kategoriId;
    decimal nilai;
    string tanggalPengajuan;
    string? tanggalRealisasi?;
    string? keterangan?;
};

# Result of a paginated pengeluaran perusahaan list query: the page of items plus pagination metadata.
#
# + items - the page of pengeluaran
# + pagination - pagination metadata
public type PengeluaranListResult record {|
    PengeluaranPerusahaan[] items;
    Pagination pagination;
|};

# ===== Finansial — Saldo Awal Kas + Posisi Kas =====

# A saldo_awal_kas (opening cash balance) row. This table is append-only by design — no
# update/delete, no soft-delete column: a correction is recorded as a new later-dated row, and the
# cash-position view always anchors on the most recent one.
#
# + id - primary key
# + tanggal - the balance date (YYYY-MM-DD)
# + nilai - the opening cash amount
# + keterangan - optional note
# + createdAt - when the row was created
# + createdBy - the `sub` claim of the creator
public type SaldoAwalKas record {|
    int id;
    string tanggal;
    decimal nilai;
    string? keterangan;
    string createdAt;
    string createdBy;
|};

# Request body for POST /api/v1/finance/saldo-awal-kas. (Append-only: there is no update/delete.)
#
# + tanggal - the balance date (YYYY-MM-DD)
# + nilai - the opening cash amount
# + keterangan - optional note
public type SaldoAwalKasCreateRequest record {|
    string tanggal;
    decimal nilai;
    string? keterangan?;
|};

# Result of a paginated saldo awal kas list query: the page of items plus pagination metadata.
#
# + items - the page of saldo awal kas rows
# + pagination - pagination metadata
public type SaldoAwalKasListResult record {|
    SaldoAwalKas[] items;
    Pagination pagination;
|};

# Current cash position (from the `v_posisi_kas` view): anchored on the most recent saldo_awal_kas,
# it adds realized inflow (PARSIAL/FINAL pencairan on/after the anchor date) and subtracts realized
# outflow (APPROVED pembayaran + pengeluaran with a realization date on/after the anchor). All the
# saldo-derived fields are nullable because they are null when no saldo_awal_kas row exists yet.
#
# + tanggalSaldoAwal - the anchor balance date, or () if no saldo_awal_kas exists
# + saldoAwal - the anchor opening balance, or () if none
# + totalInflow - realized inflow since the anchor (0 when no anchor)
# + totalOutflow - realized outflow since the anchor (0 when no anchor)
# + posisiKas - saldoAwal + totalInflow - totalOutflow, or () if no anchor
public type PosisiKas record {|
    string? tanggalSaldoAwal;
    decimal? saldoAwal;
    decimal totalInflow;
    decimal totalOutflow;
    decimal? posisiKas;
|};

# ===== Dashboard summary (public, pre-login) =====

# Top-level KPI cards shown before login. `totalProyek` counts all non-deleted proyek,
# `revenueBulanIni` sums `pencairan_tagihan.nilai` actually disbursed (PARSIAL/FINAL,
# `tanggal_pencairan`) in the current calendar month, and `proyekSedangDikerjakan` counts won
# deals (`status = 'DEAL_KONTRAK'`) whose `target_selesai` hasn't passed yet (or is unset).
#
# + totalProyek - count of all non-deleted proyek
# + revenueBulanIni - revenue disbursed in the current calendar month
# + proyekSedangDikerjakan - count of proyek currently in progress
public type DashboardSummary record {|
    int totalProyek;
    decimal revenueBulanIni;
    int proyekSedangDikerjakan;
|};

# ===== RBAC — Role =====

# A role row as returned to the client. Unlike most master tables `role` has no `is_deleted`
# column (see role_repository for why: role_permission/role_menu rows only make sense tied
# to an existing role, so delete is a hard delete). Audit columns are optional: the list
# endpoint selects only core fields, the detail endpoint also fills the audit fields.
#
# + id - primary key
# + kodeRole - unique role code
# + namaRole - role name
# + deskripsi - optional description
# + status - AKTIF / TIDAK_AKTIF
# + createdAt - creation timestamp (detail view only)
# + updatedAt - last update timestamp, or ()
# + createdBy - creator's `sub` claim (detail view only)
# + updatedBy - last updater's `sub` claim, or ()
public type Role record {|
    int id;
    string kodeRole;
    string namaRole;
    string? deskripsi;
    string status;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/roles. `status` defaults to "AKTIF" when omitted.
#
# + kodeRole - unique role code
# + namaRole - role name
# + deskripsi - optional description
# + status - optional status, defaults to "AKTIF"
public type RoleCreateRequest record {|
    string kodeRole;
    string namaRole;
    string? deskripsi?;
    string status?;
|};

# Request body for PUT /api/v1/master/roles/{id} — a full replace of the mutable fields.
#
# + kodeRole - new unique role code
# + namaRole - new role name
# + deskripsi - new description, or () to clear it
# + status - new status
public type RoleUpdateRequest record {|
    string kodeRole;
    string namaRole;
    string? deskripsi?;
    string status;
|};

# Result of a paginated role list query: the page of items plus pagination metadata.
#
# + items - the page of roles
# + pagination - pagination metadata
public type RoleListResult record {|
    Role[] items;
    Pagination pagination;
|};

# ===== RBAC — Menu (navigation tree) =====

# A menu row as returned to the client. `menu` carries no audit columns at all (no
# created_at/created_by, no is_deleted) — it is a lean, purely structural table (see A15 in
# the schema), so unlike Unit/Industri/etc there is no separate list-vs-detail projection.
#
# + id - primary key
# + parentId - parent menu id, or () for a top-level node
# + kodeMenu - unique menu code
# + namaMenu - menu label
# + path - optional frontend route
# + icon - optional icon identifier
# + urutan - display order
# + status - AKTIF / TIDAK_AKTIF
public type Menu record {|
    int id;
    int? parentId;
    string kodeMenu;
    string namaMenu;
    string? path;
    string? icon;
    int urutan;
    string status;
|};

# Request body for POST /api/v1/master/menu. `parentId` is optional/nullable (a top-level
# menu, or a pure UI grouping node, has no parent). `urutan`/`status` default to 0/"AKTIF".
#
# + parentId - optional parent menu id
# + kodeMenu - unique menu code
# + namaMenu - menu label
# + path - optional frontend route
# + icon - optional icon identifier
# + urutan - optional display order, defaults to 0
# + status - optional status, defaults to "AKTIF"
public type MenuCreateRequest record {|
    int? parentId?;
    string kodeMenu;
    string namaMenu;
    string? path?;
    string? icon?;
    int urutan?;
    string status?;
|};

# Request body for PUT /api/v1/master/menu/{id} — a full replace of the mutable fields.
#
# + parentId - new parent menu id, or () to clear it
# + kodeMenu - new unique menu code
# + namaMenu - new menu label
# + path - new frontend route, or () to clear it
# + icon - new icon identifier, or () to clear it
# + urutan - new display order
# + status - new status
public type MenuUpdateRequest record {|
    int? parentId?;
    string kodeMenu;
    string namaMenu;
    string? path?;
    string? icon?;
    int urutan;
    string status;
|};

# One node of the menu hierarchy returned by GET /api/v1/master/menu/tree.
#
# + id - menu id
# + parentId - parent menu id, or () for a root node
# + kodeMenu - menu code
# + namaMenu - menu label
# + path - optional frontend route
# + icon - optional icon identifier
# + urutan - display order
# + status - AKTIF / TIDAK_AKTIF
# + children - direct child nodes
public type MenuTreeNode record {|
    int id;
    int? parentId;
    string kodeMenu;
    string namaMenu;
    string? path;
    string? icon;
    int urutan;
    string status;
    MenuTreeNode[] children;
|};

# Result of a paginated menu list query: the page of items plus pagination metadata.
#
# + items - the page of menu rows
# + pagination - pagination metadata
public type MenuListResult record {|
    Menu[] items;
    Pagination pagination;
|};

# ===== RBAC — Modul (fixed reference list for the Role Permission matrix) =====

# A modul row — the fixed, seeded master list of application modules (A13 in the schema)
# that `role_permission` matrices are keyed against. Read-only from the API's perspective:
# no create/update/delete endpoint, only GET /api/v1/master/modul.
#
# + id - primary key
# + kodeModul - unique modul code
# + namaModul - modul display name
# + urutan - display order in the Role & Permission UI
public type Modul record {|
    int id;
    string kodeModul;
    string namaModul;
    int urutan;
|};

# ===== RBAC — Role Permission matrix =====

# One modul's grants within a role's permission matrix. Always present for every non-deleted
# modul, even when the role has no corresponding `role_permission` row yet — in that case
# every `can*` flag is false and `scope` is "ALL" (see role_permission_repository).
#
# + modulId - modul id
# + kodeModul - modul code
# + namaModul - modul display name
# + canCreate - create permission for this modul
# + canRead - read permission for this modul
# + canUpdate - update permission for this modul
# + canDelete - delete permission for this modul
# + canApprove - approve permission (Pembayaran / Pengeluaran Perusahaan only)
# + canExport - export (Excel/PDF) permission
# + scope - ALL (all data) or UNIT_SENDIRI (only the caller's own unit)
public type RolePermissionItem record {|
    int modulId;
    string kodeModul;
    string namaModul;
    boolean canCreate;
    boolean canRead;
    boolean canUpdate;
    boolean canDelete;
    boolean canApprove;
    boolean canExport;
    string scope;
|};

# Response of GET /api/v1/master/role-permissions/{roleId} — the role's full permission
# matrix (one row per modul).
#
# + roleId - the role id
# + kodeRole - role code
# + namaRole - role name
# + items - the permission matrix (one entry per modul)
public type RolePermissionMatrix record {|
    int roleId;
    string kodeRole;
    string namaRole;
    RolePermissionItem[] items;
|};

# One item of the request body for PUT /api/v1/master/role-permissions/{roleId}.
#
# + modulId - modul id these grants apply to
# + canCreate - create permission for this modul
# + canRead - read permission for this modul
# + canUpdate - update permission for this modul
# + canDelete - delete permission for this modul
# + canApprove - approve permission (Pembayaran / Pengeluaran Perusahaan only)
# + canExport - export (Excel/PDF) permission
# + scope - ALL (all data) or UNIT_SENDIRI (only the caller's own unit)
public type RolePermissionUpdateItem record {|
    int modulId;
    boolean canCreate;
    boolean canRead;
    boolean canUpdate;
    boolean canDelete;
    boolean canApprove;
    boolean canExport;
    string scope;
|};

# Request body for PUT /api/v1/master/role-permissions/{roleId} — replaces the role's entire
# permission matrix in one shot (the "Role & Permission" screen saves the whole grid at once,
# it does not diff individual cells).
#
# + items - the full set of per-modul grants to persist
public type RolePermissionUpdateRequest record {|
    RolePermissionUpdateItem[] items;
|};

# ===== RBAC — Role Menu assignment =====

# One node of the menu tree annotated with whether the role has this menu assigned, returned
# by GET /api/v1/master/role-menus/{roleId}.
#
# + id - menu id
# + parentId - parent menu id, or () for a root node
# + kodeMenu - menu code
# + namaMenu - menu label
# + path - optional frontend route
# + icon - optional icon identifier
# + urutan - display order
# + status - AKTIF / TIDAK_AKTIF
# + assigned - true if this role has this menu assigned
# + children - direct child nodes
public type RoleMenuTreeNode record {|
    int id;
    int? parentId;
    string kodeMenu;
    string namaMenu;
    string? path;
    string? icon;
    int urutan;
    string status;
    boolean assigned;
    RoleMenuTreeNode[] children;
|};

# Response of GET /api/v1/master/role-menus/{roleId} — the full menu tree with `assigned`
# flags for this role.
#
# + roleId - the role id
# + kodeRole - role code
# + namaRole - role name
# + items - the menu tree annotated with assigned flags
public type RoleMenuMatrix record {|
    int roleId;
    string kodeRole;
    string namaRole;
    RoleMenuTreeNode[] items;
|};

# Request body for PUT /api/v1/master/role-menus/{roleId} — replaces the role's entire set of
# assigned menu ids in one shot.
#
# + menuIds - the full set of menu ids to assign
public type RoleMenuUpdateRequest record {|
    int[] menuIds;
|};

# ===== Master Data — Kategori Finansial Keluar (CRUD) =====

# A kategori_finansial_keluar row — the master category referenced by Pembayaran and Pengeluaran
# Perusahaan. The table has NO update-audit columns and NO `is_deleted` column: updates rewrite
# kode/nama/status in place, and delete is physical (guarded against rows still referencing it).
#
# + id - primary key
# + kode - unique category code
# + nama - category name
# + status - AKTIF / TIDAK_AKTIF (an inactive category can't be picked for new finance rows)
# + createdAt - when the row was created
# + createdBy - the `sub` claim of the creator
public type KategoriFinansialKeluar record {|
    int id;
    string kode;
    string nama;
    string status;
    string createdAt?;
    string createdBy?;
|};

# Request body for POST /api/v1/master/kategori-finansial-keluar.
#
# + kode - unique category code (1-20 chars)
# + nama - category name (1-100 chars)
# + status - optional status (AKTIF / TIDAK_AKTIF), defaults to AKTIF
public type KategoriFinansialKeluarCreateRequest record {
    string kode;
    string nama;
    string status?;
};

# Request body for PUT /api/v1/master/kategori-finansial-keluar/{id}.
#
# + kode - unique category code
# + nama - category name
# + status - status (AKTIF / TIDAK_AKTIF)
public type KategoriFinansialKeluarUpdateRequest record {
    string kode;
    string nama;
    string status;
};

# Result of a paginated kategori finansial keluar list query.
#
# + items - the page of kategori rows
# + pagination - pagination metadata
public type KategoriFinansialKeluarListResult record {|
    KategoriFinansialKeluar[] items;
    Pagination pagination;
|};

# ===== Sales Unit — Target Sales Unit (CRUD, per unit per tahun) =====

# A target_sales_unit row: a unit's sales (deal) target for a year split across the four triwulan.
# `unitNama` is joined; `targetTotal` is the computed sum. The twin of `TargetRevenueUnit` (same
# shape, different table). This table has NO `is_deleted` column, so deletes are physical.
#
# + id - primary key
# + unitId - the unit this target belongs to
# + unitNama - joined unit name
# + tahun - the target year
# + targetTw1 - sales target for quarter 1
# + targetTw2 - sales target for quarter 2
# + targetTw3 - sales target for quarter 3
# + targetTw4 - sales target for quarter 4
# + targetTotal - computed sum of the four quarter targets
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type TargetSalesUnit record {|
    int id;
    int unitId;
    string unitNama;
    int tahun;
    decimal targetTw1;
    decimal targetTw2;
    decimal targetTw3;
    decimal targetTw4;
    decimal targetTotal;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/business/target-sales-unit. Each (unit, tahun) pair is unique; any
# omitted quarter target defaults to 0; all targets must be non-negative.
#
# + unitId - the unit to set a target for
# + tahun - the target year
# + targetTw1 - optional quarter-1 target (defaults to 0)
# + targetTw2 - optional quarter-2 target (defaults to 0)
# + targetTw3 - optional quarter-3 target (defaults to 0)
# + targetTw4 - optional quarter-4 target (defaults to 0)
public type TargetSalesUnitCreateRequest record {
    int unitId;
    int tahun;
    decimal targetTw1?;
    decimal targetTw2?;
    decimal targetTw3?;
    decimal targetTw4?;
};

# Request body for PUT /api/v1/business/target-sales-unit/{id}. Same shape/rules as create.
#
# + unitId - the unit to set a target for
# + tahun - the target year
# + targetTw1 - optional quarter-1 target (defaults to 0)
# + targetTw2 - optional quarter-2 target (defaults to 0)
# + targetTw3 - optional quarter-3 target (defaults to 0)
# + targetTw4 - optional quarter-4 target (defaults to 0)
public type TargetSalesUnitUpdateRequest record {
    int unitId;
    int tahun;
    decimal targetTw1?;
    decimal targetTw2?;
    decimal targetTw3?;
    decimal targetTw4?;
};

# Result of a paginated target sales unit list query.
#
# + items - the page of target sales unit rows
# + pagination - pagination metadata
public type TargetSalesUnitListResult record {|
    TargetSalesUnit[] items;
    Pagination pagination;
|};

# ===== Sales Unit — Sales Matrix / Pencapaian Sales Unit (target vs realisasi) =====

# One row of the Sales Matrix report (GET /api/v1/business/sales-matrix): a unit's sales target vs
# actual deal realisasi for a year, broken down by triwulan plus totals and achievement. `target*`
# come from `target_sales_unit`; `realisasi*` are deal-basis actuals from the `v_realisasi_sales_tw`
# view (sum of DEAL_KONTRAK proyek `nilai_bersih` grouped by unit and deal quarter).
#
# + unitId - the unit
# + unitNama - joined unit name
# + tahun - the report year
# + targetTw1 - quarter-1 target
# + targetTw2 - quarter-2 target
# + targetTw3 - quarter-3 target
# + targetTw4 - quarter-4 target
# + targetTotal - sum of the four quarter targets
# + realisasiTw1 - quarter-1 actual sales
# + realisasiTw2 - quarter-2 actual sales
# + realisasiTw3 - quarter-3 actual sales
# + realisasiTw4 - quarter-4 actual sales
# + realisasiTotal - sum of the four quarter actuals
# + pencapaianPersen - realisasiTotal / targetTotal * 100 (0 when target is 0)
public type SalesUnitRow record {|
    int unitId;
    string unitNama;
    int tahun;
    decimal targetTw1;
    decimal targetTw2;
    decimal targetTw3;
    decimal targetTw4;
    decimal targetTotal;
    decimal realisasiTw1;
    decimal realisasiTw2;
    decimal realisasiTw3;
    decimal realisasiTw4;
    decimal realisasiTotal;
    decimal pencapaianPersen;
|};

# One row of the Sales Matrix per-Triwulan report (GET /api/v1/business/sales-matrix/tw).
#
# + unitId - the unit
# + unitNama - joined unit name
# + tahun - the report year
# + triwulan - the quarter (1..4)
# + target - the unit's target for that quarter
# + realisasi - the unit's actual sales for that quarter
# + pencapaianPersen - realisasi / target * 100 (0 when target is 0)
public type SalesUnitTwRow record {|
    int unitId;
    string unitNama;
    int tahun;
    int triwulan;
    decimal target;
    decimal realisasi;
    decimal pencapaianPersen;
|};

# One point of the Sales Matrix chart: aggregated target vs realisasi for a single quarter.
#
# + triwulan - the quarter (1..4)
# + label - the quarter label ("TW1".."TW4")
# + target - total target for the quarter (one unit, or summed across all units)
# + realisasi - total actual sales for the quarter (one unit, or summed across all units)
public type SalesUnitChartPoint record {|
    int triwulan;
    string label;
    decimal target;
    decimal realisasi;
|};

# The Sales Matrix chart (GET /api/v1/business/sales-matrix/chart): four quarter points of target vs
# realisasi for a year, for a single unit or aggregated across all units.
#
# + tahun - the chart year
# + unitId - the single unit the chart is scoped to, or null when aggregated
# + unitNama - the single unit's name, or null when aggregated
# + points - the four quarter points (TW1..TW4)
public type SalesUnitChart record {|
    int tahun;
    int? unitId;
    string? unitNama;
    SalesUnitChartPoint[] points;
|};

# ===== Resource Unit (CRUD, one row per unit) =====

# A resource_unit row: capacity/headcount info for a unit. One row per unit (uq_resource_unit_unit).
# `unitNama` and `leadNama` are joined (no N+1); `leadId`/`leadNama` are null when no lead is set.
#
# + id - primary key
# + unitId - the unit this resource row belongs to (unique)
# + unitNama - joined unit name
# + leadId - the karyawan id of the unit lead, or null
# + leadNama - joined lead name, or null
# + jumlah - headcount
# + kapasitasTerpakai - used capacity percentage (0..100)
# + status - AKTIF / TIDAK_AKTIF
# + createdAt - when the row was created
# + updatedAt - when the row was last updated (null if never)
# + createdBy - the `sub` claim of the creator
# + updatedBy - the `sub` claim of the last updater (null if never)
public type ResourceUnit record {|
    int id;
    int unitId;
    string unitNama;
    int? leadId;
    string? leadNama;
    int jumlah;
    decimal kapasitasTerpakai;
    string status;
    string createdAt?;
    string? updatedAt?;
    string createdBy?;
    string? updatedBy?;
|};

# Request body for POST /api/v1/master/resource-unit. One resource row per unit (unique).
#
# + unitId - the unit to create a resource row for
# + leadId - optional karyawan id of the unit lead
# + jumlah - optional headcount (defaults to 0, must be >= 0)
# + kapasitasTerpakai - optional used-capacity percentage (defaults to 0, 0..100)
# + status - optional status (AKTIF / TIDAK_AKTIF), defaults to AKTIF
public type ResourceUnitCreateRequest record {
    int unitId;
    int? leadId?;
    int jumlah?;
    decimal kapasitasTerpakai?;
    string status?;
};

# Request body for PUT /api/v1/master/resource-unit/{id}. Same shape/rules as create.
#
# + unitId - the unit this resource row belongs to
# + leadId - optional karyawan id of the unit lead
# + jumlah - optional headcount (defaults to 0, must be >= 0)
# + kapasitasTerpakai - optional used-capacity percentage (defaults to 0, 0..100)
# + status - status (AKTIF / TIDAK_AKTIF)
public type ResourceUnitUpdateRequest record {
    int unitId;
    int? leadId?;
    int jumlah?;
    decimal kapasitasTerpakai?;
    string status;
};

# Result of a paginated resource unit list query.
#
# + items - the page of resource unit rows
# + pagination - pagination metadata
public type ResourceUnitListResult record {|
    ResourceUnit[] items;
    Pagination pagination;
|};

# ===== Cashflow (report) =====

# One month of the Cashflow report: inflow (cash-in from pencairan) vs outflow (approved+realized
# pembayaran + pengeluaran) and their net, company-wide.
#
# + bulan - the month number (1..12)
# + label - the month label ("Jan".."Des")
# + inflow - total cash-in that month
# + outflow - total cash-out that month
# + net - inflow - outflow
public type CashflowMonth record {|
    int bulan;
    string label;
    decimal inflow;
    decimal outflow;
    decimal net;
|};

# The Cashflow report (GET /api/v1/business/cashflow) for a year: twelve monthly inflow/outflow/net
# rows plus year totals and the current cash position (from `v_posisi_kas`).
#
# + tahun - the report year
# + months - the twelve monthly rows (Jan..Des)
# + totalInflow - sum of monthly inflow for the year
# + totalOutflow - sum of monthly outflow for the year
# + netTotal - totalInflow - totalOutflow
# + posisiKasTerkini - the latest cash position from v_posisi_kas (null when no saldo awal exists)
public type CashflowReport record {|
    int tahun;
    CashflowMonth[] months;
    decimal totalInflow;
    decimal totalOutflow;
    decimal netTotal;
    decimal? posisiKasTerkini;
|};

# One point of the Cashflow chart: a single month's inflow vs outflow.
#
# + bulan - the month number (1..12)
# + label - the month label ("Jan".."Des")
# + inflow - total cash-in that month
# + outflow - total cash-out that month
public type CashflowChartPoint record {|
    int bulan;
    string label;
    decimal inflow;
    decimal outflow;
|};

# ===== Manajemen User — write operations (SCIM2) =====

# Request body for POST /api/v1/manajemen-user — provisions a new WSO2 IS user via SCIM2.
#
# + userName - the login username (unique in WSO2 IS)
# + email - the user's email
# + nama - the user's display name (mapped to SCIM `name.formatted` / givenName)
# + password - the initial password
# + roleId - optional portal role id, written to the `swaportal_role_id` custom attribute
public type UserCreateRequest record {
    string userName;
    string email;
    string nama;
    string password;
    int? roleId?;
};

# Request body for PUT /api/v1/manajemen-user/{subjectId} — updates a user's profile via SCIM2.
#
# + email - the user's new email
# + nama - the user's new display name
public type UserUpdateRequest record {
    string email;
    string nama;
};

# Request body for PUT /api/v1/manajemen-user/{subjectId}/role — sets the portal role.
#
# + roleId - the portal role id to write to `swaportal_role_id`, or () to clear it
public type UserRoleUpdateRequest record {
    int? roleId;
};

# Request body for PUT /api/v1/manajemen-user/{subjectId}/status — enables/disables the account.
#
# + active - true to enable the account, false to disable it (SCIM `active`)
public type UserStatusUpdateRequest record {
    boolean active;
};

# ===== Akun Saya / Manajemen User "akun" — fuller WSO2 IS identity updates =====
#
# Request body for PUT /api/v1/akun-saya — updates the CALLER's OWN identity record in WSO2
# Identity Server (login credentials/profile), NOT the local karyawan HR contact record (see
# ProfilSayaUpdateRequest and its note on why the two are deliberately separate). Every field is
# optional: only fields actually present in the payload are sent to WSO2 IS, everything else is
# left untouched. `swaportal_role_id` is deliberately NOT here — self-service role change would let
# any user grant themselves a higher-privilege role, so role changes stay admin-only (see
# UserAccountUpdateRequest / PUT /api/v1/manajemen-user/{subjectId}/akun, or the pre-existing
# PUT /api/v1/manajemen-user/{subjectId}/role).
#
# Password is NOT here — it is changed via the dedicated PUT /api/v1/akun-saya/password
# (PasswordUpdateRequest), separate from the data-update form.
#
# + email - optional new email (SCIM `emails` + WSO2 `emailAddresses`)
# + firstName - optional new first name (SCIM `name.givenName`)
# + lastName - optional new last name (SCIM `name.familyName`)
# + telepon - optional new mobile number (SCIM `phoneNumbers` + WSO2 `mobileNumbers`); "" clears it
# + organization - optional organization (SCIM enterprise `organization`)
# + country - optional country (WSO2 `country`)
public type AkunSayaUpdateRequest record {|
    string email?;
    string firstName?;
    string lastName?;
    string telepon?;
    string organization?;
    string country?;
|};

# Request body for PUT /api/v1/akun-saya/password (self) and
# PUT /api/v1/manajemen-user/{subjectId}/password (admin reset) — changing the password is a separate
# operation from the data-update form (URL-Doc-IS7 §4).
#
# + password - the new password (min 6 chars)
public type PasswordUpdateRequest record {|
    string password;
|};

# Request body for PUT /api/v1/manajemen-user/{subjectId}/akun — Super Admin updates ANOTHER user's
# full WSO2 IS identity (password reset, contact info, and portal role) in a single call, using the
# Super Admin IS account (config:scimAdminUsername/scimAdminPassword) rather than the app-level
# credential used by the simpler create/update/role/status endpoints. Same optional-field semantics
# as AkunSayaUpdateRequest, plus `roleId`. To CLEAR a role (set it to none), use the pre-existing
# PUT /api/v1/manajemen-user/{subjectId}/role instead — this endpoint only ever sets a role when
# `roleId` is present, it never clears one.
#
# The FE update form sends exactly: First Name, Last Name, Organization, Country, Email Addresses,
# Mobile Numbers, Swamedia Portal Role ID, Swamedia Portal Group ID. Password is NOT here — an admin
# resets it via the dedicated PUT /api/v1/manajemen-user/{subjectId}/password (PasswordUpdateRequest).
#
# + email - optional new email (SCIM `emails` + WSO2 `emailAddresses`)
# + firstName - optional new first name (SCIM `name.givenName`)
# + lastName - optional new last name (SCIM `name.familyName`)
# + telepon - optional new mobile number (SCIM `phoneNumbers` + WSO2 `mobileNumbers`); "" clears it
# + organization - optional organization (SCIM enterprise `organization`)
# + country - optional country (WSO2 `country`)
# + roleId - optional new portal role id (custom `swaportal_role_id`)
# + groupId - optional portal group id (custom `swaportal_group_id`, e.g. "swamedia_portal_app")
public type UserAccountUpdateRequest record {|
    string email?;
    string firstName?;
    string lastName?;
    string telepon?;
    string organization?;
    string country?;
    int roleId?;
    string groupId?;
|};

# Response of PUT /api/v1/akun-saya and PUT /api/v1/manajemen-user/{subjectId}/akun — a snapshot of
# the identity fields WSO2 IS reports back right after the update. `password` is never echoed back.
#
# + subjectId - the WSO2 IS subject id that was updated
# + email - the current email on file in WSO2 IS, or () if IS did not return one
# + firstName - the current first (given) name, or ()
# + lastName - the current last (family) name, or ()
# + telepon - the current mobile number, or ()
# + organization - the current organization, or ()
# + country - the current country, or ()
# + roleId - the current `swaportal_role_id`, or () if unset/not resolvable from the response
# + groupId - the current `swaportal_group_id`, or ()
public type AkunProfile record {|
    string subjectId;
    string? email;
    string? firstName;
    string? lastName;
    string? telepon;
    string? organization;
    string? country;
    int? roleId;
    string? groupId;
|};
