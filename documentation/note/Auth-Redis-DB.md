# Auth, Redis, dan Database — Dokumentasi Implementasi

Dokumen ini menjelaskan **apa yang sudah benar-benar diterapkan** di backend
`swamedia_portal_be` untuk tiga bagian: autentikasi (WSO2 Identity Server),
cache (Redis), dan database (PostgreSQL). Berbeda dengan
[README.md](README.md) yang berisi panduan/tutorial membuat API baru,
dokumen ini adalah catatan kondisi kode saat ini.

---

## 1. Autentikasi (WSO2 Identity Server)

### 1.1 Arsitektur

Backend ini berperan sebagai **BFF (Backend-For-Frontend)** di depan WSO2
Identity Server (IS). Frontend **tidak pernah** bicara langsung ke WSO2 IS —
semua request auth masuk lewat backend, dan backend yang menyimpan
`clientId`/`clientSecret`/URL WSO2 IS. Ini mencegah credential OAuth2 bocor
ke browser.

```text
Frontend  --->  Backend (/api/v1/auth/*)  --->  WSO2 Identity Server
```

Alur ini memakai **WSO2 Identity API Server "Native Auth" flow** (init →
authenticate → token), bukan redirect-based Authorization Code flow biasa.
Artinya username/password dikirim dari frontend ke backend, lalu backend
yang meneruskannya ke WSO2 secara server-to-server.

### 1.2 Endpoint yang tersedia

Semua endpoint ada di [main.bal](../main.bal), di bawah service
`/api/v1/auth`:

| Method | Endpoint | Fungsi | Wrap ke WSO2 IS |
| --- | --- | --- | --- |
| `POST` | `/api/v1/auth/init` | Mulai flow autentikasi, dapat `flowId` + daftar authenticator | `POST /oauth2/authorize` |
| `POST` | `/api/v1/auth/login` | Login sekali jalan: init → authenticate → token exchange | `authorize` + `authn` + `token` |
| `POST` | `/api/v1/auth/token` | Tukar authorization code jadi token set | `POST /oauth2/token` (grant `authorization_code`) |
| `POST` | `/api/v1/auth/refresh` | Tukar refresh token jadi token set baru | `POST /oauth2/token` (grant `refresh_token`) |
| `GET` | `/api/v1/auth/userinfo` | Ambil klaim user dari access token (pakai cache) | `GET /oauth2/userinfo` |
| `POST` | `/api/v1/auth/introspect` | Cek status aktif/tidaknya token | `POST /oauth2/introspect` |
| `POST` | `/api/v1/auth/revoke` | Cabut access/refresh token | `POST /oauth2/revoke` |
| `POST` | `/api/v1/auth/logout` | Akhiri sesi user di WSO2 IS | `POST /oidc/logout` |

Endpoint contoh yang dilindungi JWT (lihat 1.4):

| Method | Endpoint | Fungsi |
| --- | --- | --- |
| `GET` | `/api/v1/business/ping` | Contoh endpoint bisnis — hanya bisa diakses dengan access token valid |

### 1.3 Alur `login` (yang paling sering dipakai)

Fungsi `login()` di [services.bal](../modules/services/services.bal)
menjalankan 3 langkah WSO2 sekaligus:

1. **Init** — `repositories:initAuthFlow()` memanggil `POST /oauth2/authorize`
   dengan `client_id`, `client_secret`, `redirect_uri`, `scope`. WSO2
   mengembalikan `flowId` dan daftar `authenticators` yang tersedia (mis.
   Username & Password, Google, dsb).
2. **Pilih authenticator LOCAL** — kode mencari authenticator dengan
   `idp == "LOCAL"` (authenticator Username & Password bawaan WSO2). Kalau
   tidak ada, request ditolak dengan error internal.
3. **Authenticate** — `repositories:submitUsernamePassword()` memanggil
   `POST /oauth2/authn` dengan `flowId`, `authenticatorId`, `username`,
   `password`. Kalau `flowStatus != "SUCCESS_COMPLETED"`, dianggap
   username/password salah → `401 UNAUTHORIZED`.
4. **Token exchange** — authorization `code` hasil langkah 3 ditukar ke
   token set lewat `exchangeToken()` (`POST /oauth2/token`, grant
   `authorization_code`).

Endpoint `/init`, `/token`, dan `/refresh` adalah versi terpisah dari
langkah-langkah di atas, dipakai kalau frontend ingin mengontrol flow
sendiri (mis. menampilkan pilihan authenticator ke user) alih-alih memakai
`/login` yang sudah digabung.

### 1.4 Proteksi endpoint bisnis dengan JWT (JWKS)

Service `/api/v1/business` di `main.bal` memakai
`@http:ServiceConfig { auth: [...] }` bawaan Ballerina:

```ballerina
@http:ServiceConfig {
    auth: [
        {
            jwtValidatorConfig: {
                issuer: config:jwtIssuer,
                audience: config:clientId,
                signatureConfig: {
                    jwksConfig: {url: config:jwksUrl}
                }
            }
        }
    ]
}
service /api/v1/business on apiListener { ... }
```

Ballerina otomatis memvalidasi **signature (via JWKS), expiry, issuer, dan
audience** dari `Authorization: Bearer <token>` di setiap request, dan
langsung balas `401` sebelum resource function jalan kalau salah satu gagal.
Tidak ada kode validasi manual per endpoint.

**Pola ini yang harus dipakai untuk setiap service bisnis baru** — tinggal
copy blok `@http:ServiceConfig` di atas ke `service` baru.

### 1.4.1 Denylist token setelah revoke/logout

Validasi JWKS di atas murni **stateless** (cuma cek signature/exp/iss/aud dari token itu
sendiri), jadi tanpa tambahan apa pun, access token yang sudah di-revoke atau di-logout
tetap diterima sampai `exp`-nya lewat sendiri. Untuk menutup celah itu,
[main.bal](../main.bal) punya `TokenDenylistInterceptor`: sebuah
`http:RequestInterceptor` yang dijalankan **sebelum** validasi JWKS lewat
`createInterceptors()` di tiap service terproteksi, dan menolak (401) request yang
`Authorization: Bearer`-nya cocok dengan token yang sudah di-denylist.

- `services:revoke()` men-denylist token yang diminta setelah WSO2 IS berhasil
  mencabutnya.
- `services:logout()` men-denylist `accessToken` **kalau** dikirim di body
  `LogoutRequest` (field opsional, di luar `idToken` yang wajib) — frontend perlu
  mengirim access token yang sedang dipakai supaya benar-benar langsung tidak bisa
  dipakai lagi setelah logout.
- Penyimpanannya `modules/utils/token_denylist.bal`: **in-memory** (`isolated map` +
  `lock`), bukan Redis — sengaja, supaya validasi JWKS yang sudah ada tidak diganti,
  ini cuma pre-check di depannya. Konsekuensinya: data hilang saat restart, dan tidak
  ke-share kalau backend di-scale jadi banyak instance.
- Karena `service /path on listener { ... }` tidak mendukung type inclusion
  (`*http:InterceptableService;`), tiap service cukup punya method
  `public function createInterceptors() returns http:Interceptor[] => [tokenDenylistInterceptor];`
  — Ballerina mendeteksinya secara structural typing.

### 1.5 Model data auth

Didefinisikan di [models.bal](../modules/models/models.bal):

- `AuthInitResponse`, `AuthInitAuthenticator`, `AuthnResponse`, `AuthnData`,
  `TokenResponse` — bentuk response mentah dari WSO2 IS (record terbuka
  karena WSO2 bisa mengirim field tambahan).
- `LoginRequest`, `TokenExchangeRequest`, `RefreshRequest`,
  `IntrospectRequest`, `RevokeRequest`, `LogoutRequest` — request body dari
  frontend.
- `InitResponse`, `LoginResponse`, `IntrospectResponse` — response publik
  yang dikembalikan backend ke frontend (sudah "dibersihkan" dari detail
  internal WSO2).
- `AppError` — distinct error type berisi `code` (mis. `UNAUTHORIZED`,
  `VALIDATION_ERROR`, `INTERNAL_ERROR`) dan `statusCode` HTTP. Semua fungsi
  di `services.bal` mengembalikan `T|models:AppError`, lalu
  `main.bal:errorToResponse()` memetakannya ke HTTP response yang konsisten.

### 1.6 Penanganan error & keamanan pesan

- Error dari WSO2 IS (status bukan 200) dibungkus lewat
  `errorFromResponse()` di [repositories.bal](../modules/repositories/repositories.bal)
  supaya penyebab asli (mis. `invalid_client`, `invalid_grant`) masuk log
  server, **bukan** dikirim ke client.
- Di `main.bal:errorToResponse()`, error dengan `statusCode >= 500`
  di-log lengkap tapi pesan yang dikirim ke client diseragamkan jadi
  `"Terjadi kesalahan pada server, silakan coba lagi nanti"` — supaya detail
  internal tidak bocor ke frontend.
- Error `4xx` (validasi, unauthorized) mengirim pesan aslinya karena aman
  dan berguna untuk user (mis. `"Username atau password salah"`).

### 1.7 id_token decoding

`utils:decodeIdTokenClaims()` men-decode payload JWT `id_token` **tanpa**
verifikasi ulang signature — karena token ini didapat langsung dari WSO2 IS
lewat koneksi TLS server-to-server, jadi cukup dipercaya untuk membaca klaim
user (`sub`, `email`, `name`, dst) yang ditampilkan ke frontend. (Access
token yang dipakai untuk otorisasi endpoint bisnis tetap diverifikasi penuh
lewat JWKS, lihat 1.4.)

### 1.8 Konfigurasi auth (`modules/config/config.bal`)

| Variable | Default | Keterangan |
| --- | --- | --- |
| `clientId` | `""` | Client ID aplikasi OAuth2 di WSO2 IS |
| `clientSecret` | `""` | Client secret OAuth2 |
| `redirectUri` | `""` | Redirect URI terdaftar di WSO2 IS |
| `iamBaseUrl` | `https://iam.apicentrum.biz.id` | Base host WSO2 IS |
| `loginScope` | `openid internal_login` | Scope yang diminta saat login |
| `authorizePath`, `authnPath`, `tokenPath`, `userinfoPath`, `introspectPath`, `revokePath`, `logoutPath`, `jwksPath` | path standar WSO2 IS 7.x | Path relatif terhadap `iamBaseUrl` |
| `jwtIssuer` | `https://iam.apicentrum.biz.id/oauth2/token` | Harus cocok klaim `iss` di access token |
| `jwksUrl` | `https://iam.apicentrum.biz.id/oauth2/jwks` | Endpoint JWKS untuk validasi signature |

`clientId`/`clientSecret`/`redirectUri` defaultnya kosong supaya `bal
build`/`bal test` tetap jalan tanpa `Config.toml`; nilai asli di-override
lewat `Config.toml` (gitignored) di root project.

---

## 2. Redis (cache)

### 2.1 Status: generik, disiapkan untuk pemakaian mendatang

Redis **belum dipakai untuk fitur bisnis apa pun** secara wajib — satu-satunya
pemakaian saat ini adalah **cache-aside untuk `userinfo`** (lihat 2.3), dan
itu pun bersifat *nice-to-have* (kalau Redis mati, request tetap jalan).

### 2.2 Lokasi kode & API

[modules/repositories/cache.bal](../modules/repositories/cache.bal) menyediakan
3 fungsi publik generik (JSON in, JSON out):

```ballerina
repositories:cacheSet(key, value, ttlSeconds = 0)   // simpan; ttlSeconds = 0 = tanpa expiry
repositories:cacheGet(key)                          // baca; () kalau cache miss
repositories:cacheDelete(...keys)                    // hapus satu/lebih key
```

Client Redis (`redis:Client`) **lazy** — baru dibuat saat fungsi cache
pertama kali dipanggil (pola `isolated ... Client? cachedClient = ()` + lock),
bukan saat module di-load. Ini supaya `bal build`/`bal test` tidak pernah
butuh Redis menyala; hanya `bal run` (atau test yang benar-benar memanggil
fungsi cache) yang butuhnya.

### 2.3 Pemakaian nyata: cache userinfo

Di `services:userInfo()` ([services.bal](../modules/services/services.bal)):

1. Key cache dibentuk dari hash SHA-256 access token:
   `"userinfo:" + sha256(accessToken)` — token asli tidak pernah dipakai
   sebagai key mentah.
2. Coba `cacheGet(cacheKey)` dulu. Kalau hit → langsung dikembalikan, tidak
   panggil WSO2 IS.
3. Kalau miss atau Redis error (di-log, tidak melempar error ke caller) →
   panggil `repositories:getUserInfo()` ke WSO2 IS.
4. Hasilnya disimpan ke cache dengan TTL **60 detik**
   (`USERINFO_CACHE_TTL_SECONDS`).

Pola ini ("Redis nice-to-have, gagal = fallback diam-diam") adalah contoh
yang disarankan untuk dipakai ulang di fitur bisnis lain yang butuh caching.

### 2.4 Konfigurasi Redis

| Variable | Default | Keterangan |
| --- | --- | --- |
| `redisHost` | `localhost` | Host Redis |
| `redisPort` | `6379` | Port Redis |
| `redisPassword` | `""` (tanpa auth) | Password Redis, kosong = tanpa `AUTH` |
| `redisDatabase` | `0` | Nomor database Redis (`SELECT n`) |
| `redisConnectionTimeoutSeconds` | `3` | Timeout koneksi |

Default-nya cocok dengan `docker-compose.yml` di root project — jalankan
`docker compose up -d` untuk Redis lokal.

---

## 3. Database (PostgreSQL)

### 3.1 Status: client sudah tersedia, belum dipakai fitur bisnis

Koneksi PostgreSQL **baru selesai disiapkan** (client + konfigurasi) dan
sudah diverifikasi bisa connect ke database lokal (`SELECT 1` berhasil).
**Belum ada** repository/query bisnis nyata yang memakainya — tabel
`Schemas`/data di `swamedia_portal_db` (lihat
[swamedia_portal_v1.6.sql](swamedia_portal_v1.6.sql)) belum diakses dari
kode manapun. Ini adalah fondasi untuk fitur-fitur berikutnya.

### 3.2 Lokasi kode & API

[modules/repositories/db.bal](../modules/repositories/db.bal):

```ballerina
public isolated function dbClient() returns postgresql:Client|error
```

Sama seperti Redis, client ini **lazy** — connection pool baru dibuat saat
`dbClient()` pertama kali dipanggil, di-cache di variabel module-level
`cachedDbClient`, dan dipakai ulang untuk semua pemanggilan berikutnya.
`bal build`/`bal test` tidak butuh Postgres menyala; hanya `bal run` (atau
kode yang benar-benar memanggil `dbClient()`) yang butuh.

Driver JDBC PostgreSQL di-bundle lewat:

```ballerina
import ballerinax/postgresql.driver as _;
```

(wajib ada — tanpa ini akan muncul error runtime "Error while loading
database driver" walau dependency `ballerinax/postgresql` sudah terpasang).

### 3.3 Cara pakai di repository baru

Karena `dbClient()` mengembalikan `postgresql:Client` mentah, pemakaiannya
memakai API standar module `ballerina/sql`, contoh:

```ballerina
import ballerina/sql;
import rayha/swamedia_portal_be.repositories;

public function findUserByEmail(string email) returns User|error {
    postgresql:Client dbc = check repositories:dbClient();
    stream<User, sql:Error?> result = dbc->query(
        `SELECT id, name, email FROM users WHERE email = ${email}`
    );
    // ... consume stream
}
```

Ikuti pola layer di [README.md](README.md#arsitektur-restful-api): query SQL
ditulis di `modules/repositories`, dipanggil dari `modules/services`, tidak
pernah langsung dari `main.bal`.

### 3.4 Konfigurasi Database

| Variable | Default | Keterangan |
| --- | --- | --- |
| `dbHost` | `localhost` | Host PostgreSQL |
| `dbPort` | `5432` | Port PostgreSQL |
| `dbName` | `swamedia_portal_db` | Nama database |
| `dbUser` | `postgres` | Username |
| `dbPassword` | `""` | Password — **wajib diisi lewat `Config.toml` lokal**, jangan pernah di-commit |
| `dbMaxOpenConnections` | `10` | Ukuran maksimum connection pool |

Contoh isi `Config.toml` (root project, gitignored) untuk development lokal:

```toml
[rayha.swamedia_portal_be.config]
dbHost = "localhost"
dbPort = 5432
dbName = "swamedia_portal_db"
dbUser = "postgres"
dbPassword = "isi-password-lokal-anda"
```

### 3.5 Catatan penting: `bal test` menyembunyikan nilai `*Password`/`*Secret`

Configurable variable yang namanya mengandung `Password` atau `Secret`
(mis. `dbPassword`, `clientSecret`) **selalu terbaca kosong saat `bal
test`**, walau sudah diisi di `Config.toml` — ini perilaku keamanan bawaan
Ballerina supaya secret tidak bocor lewat log test. Variable lain
(`dbHost`, `dbUser`, dst) tetap terbaca normal.

Konsekuensinya: kalau ingin menulis test yang benar-benar connect ke
Postgres/WSO2 dengan credential asli, **jangan** pakai `bal test` — jalankan
lewat `bal run` (lihat pola verifikasi manual yang dipakai untuk memvalidasi
`dbClient()`: fungsi `init()` di module yang memanggil `dbClient()` lalu
query kecil, dijalankan sekali dengan `bal run`, lalu dihapus lagi setelah
terbukti jalan).
