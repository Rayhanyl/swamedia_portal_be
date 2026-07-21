# Modul: Autentikasi (`/api/v1/auth`)

Backend berperan sebagai **BFF (Backend for Frontend)** di depan WSO2 Identity Server. Frontend
**tidak pernah** berkomunikasi langsung dengan WSO2 IS: seluruh URL IS, client credential, `flowId`,
dan authorization code tetap berada di backend.

Semua endpoint di modul ini **publik** (tidak butuh `Authorization`), kecuali `GET /userinfo` yang
justru membutuhkan access token — karena tujuannya memang membaca klaim token tersebut.

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| POST | `/api/v1/auth/init` | Memulai flow autentikasi (opsional) |
| POST | `/api/v1/auth/login` | Login username/password → langsung dapat token |
| POST | `/api/v1/auth/token` | Menukar authorization code menjadi token |
| POST | `/api/v1/auth/refresh` | Memperbarui access token yang kedaluwarsa |
| GET | `/api/v1/auth/userinfo` | Klaim OIDC milik access token |
| POST | `/api/v1/auth/introspect` | Memeriksa status/aktif tidaknya token |
| POST | `/api/v1/auth/revoke` | Mencabut token |
| POST | `/api/v1/auth/logout` | Mengakhiri sesi di WSO2 IS |

## Alur yang Dipakai Frontend

**Untuk login form biasa, cukup panggil `POST /login` saja.** Endpoint itu menjalankan seluruh
rangkaian (init → authenticate → token exchange) di sisi server dan langsung mengembalikan token
lengkap. `/init` dan `/token` hanya diperlukan bila suatu saat frontend perlu menangani sendiri
langkah authenticator (mis. MFA), dan pada alur normal tidak dipakai.

```
POST /login  ──► { accessToken, refreshToken, idToken, user }
   │
   ├── simpan token
   ├── GET /api/v1/menu-saya   (menu sesuai role)
   └── setiap request berikutnya: Authorization: Bearer <accessToken>

access token kedaluwarsa (401)
   └── POST /refresh ──► token baru ──► ulangi request

logout
   └── POST /logout { idToken, accessToken }
```

---

## `POST /api/v1/auth/init`

Memulai flow autentikasi (membungkus `/oauth2/authorize` milik IS). Mengembalikan `flowId` dan
daftar authenticator yang ditawarkan IS. **Opsional** — pada alur login normal, lewati saja.

Tidak ada request parameter maupun body.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Flow autentikasi berhasil dimulai",
  "data": {
    "flowId": "f0d9c1a2-3b4e-5678-9abc-def012345678",
    "authenticators": [
      {
        "authenticatorId": "QmFzaWNBdXRoZW50aWNhdG9yOkxPQ0FM",
        "authenticator": "Username & Password",
        "idp": "LOCAL",
        "requiredParams": ["username", "password"]
      }
    ]
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T03:20:11.004Z" }
}
```

| Field | Keterangan |
| --- | --- |
| `flowId` | Id flow yang dibawa ke langkah login berikutnya. |
| `authenticators[]` | Opsi authenticator yang ditawarkan IS (`authenticatorId`, `authenticator`, `idp`, `requiredParams`). |

**Status:** `200` berhasil · `500` IS tidak dapat dihubungi/menolak.

---

## `POST /api/v1/auth/login`

Login dengan username/password. Menjalankan init → authenticate → token exchange terhadap IS di
sisi server, lalu mengembalikan token set lengkap beserta data user yang sudah di-decode.

**Efek samping:** setiap login berhasil di sini men-sync klaim `sub`/`name`/`email` ke `user_cache`
(best-effort — gagal di-log, tidak pernah menggagalkan login). Baris yang datanya sudah identik
di-skip, tidak ditulis ulang. Lihat [Manajemen User](04-rbac.md#modul-manajemen-user) untuk detail.

**Body (`application/json`)**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `username` | string | ya | Username login user. |
| `password` | string | ya | Password login user. |

**Contoh request**

```http
POST /api/v1/auth/login
Content-Type: application/json

{ "username": "budi.santoso", "password": "RahasiaKu123!" }
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Login berhasil",
  "data": {
    "accessToken": "eyJ4NXQiOiJOVGRtWmpNNFpEazNOalkwWXpjNU1tW...",
    "refreshToken": "8f2c1d9a-5e3b-4c7d-9a1f-2b6e4d8c0a3f",
    "idToken": "eyJ4NXQiOiJOVGRtWmpNNFpEazNOalkwWXpjNU1qW...",
    "tokenType": "Bearer",
    "expiresIn": 3600,
    "scope": "openid profile",
    "user": {
      "sub": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "email": "budi.santoso@swamedia.co.id",
      "name": "Budi Santoso",
      "swaportal_role_id": "3",
      "swaportal_role_name": "Manager"
    }
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T03:21:45.882Z" }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `accessToken` | Dikirim sebagai `Authorization: Bearer <accessToken>` di **setiap** request lain. |
| `refreshToken` | Dipakai `POST /refresh` saat access token kedaluwarsa. Simpan seaman access token. |
| `idToken` | **Wajib** dikirim saat `POST /logout`. Kalau hilang, sesi di IS tidak bisa diakhiri. |
| `tokenType` | Selalu `"Bearer"`. |
| `expiresIn` | Umur access token dalam **detik** sejak diterbitkan (bukan timestamp kedaluwarsa). |
| `user` | Klaim id_token hasil decode. `user.sub` adalah identitas user yang dipakai backend untuk field audit. `user.swaportal_role_id` menunjuk role portal yang menentukan menu & permission. |
| `user.swaportal_role_name` | **Bukan klaim asli dari IS** — ditambahkan backend dengan resolve `swaportal_role_id` ke tabel `role` lokal, supaya frontend tidak perlu request tambahan hanya untuk nama role. Hilang (tidak ada key-nya) kalau `swaportal_role_id` kosong/tidak valid/role sudah dihapus — jangan asumsikan selalu ada. |

**Status**

| Status | Keterangan |
| --- | --- |
| `200` | Login berhasil. |
| `400` | `username`/`password` kosong atau body tidak sesuai bentuk. |
| `401` | Kredensial salah — tampilkan "username atau password salah". |
| `500` | IS tidak dapat dihubungi atau membalas tak terduga. |

---

## `POST /api/v1/auth/token`

Menukar authorization code menjadi token (membungkus `/oauth2/token` grant `authorization_code`).
Hanya relevan bila frontend menjalankan sendiri langkah authenticator; alur login normal memakai
`/login`.

Endpoint ini yang sebenarnya dipanggil `/login` di baliknya (`services:login` mendelegasikan ke
`services:exchangeToken`), jadi **efek samping sync `user_cache`nya sama** — lihat catatan di
[`POST /login`](#post-apiv1authlogin) di atas.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `code` | string | ya | Authorization code hasil flow login/init. |

**Response:** identik dengan `POST /login` (`LoginResponse`), dengan `message` = `"Token berhasil diambil"`.

**Status:** `200` berhasil · `400` code kosong · `401` code invalid/kedaluwarsa/sudah terpakai · `500` kegagalan IS.

---

## `POST /api/v1/auth/refresh`

Memperbarui access token yang kedaluwarsa (membungkus `/oauth2/token` grant `refresh_token`).
**Tidak** memicu sync `user_cache` — refresh dianggap perpanjangan sesi diam-diam, bukan login baru.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `refreshToken` | string | ya | Refresh token yang didapat saat login. Perhatikan: **camelCase**, bukan `refresh_token`. |

**Contoh request**

```http
POST /api/v1/auth/refresh
Content-Type: application/json

{ "refreshToken": "8f2c1d9a-5e3b-4c7d-9a1f-2b6e4d8c0a3f" }
```

**Response:** bentuk sama dengan `POST /login` (`LoginResponse`), `message` = `"Token berhasil diperbarui"`.
Response biasanya membawa `refreshToken` **baru** — timpa yang lama, jangan pakai ulang yang sebelumnya.

**Status:** `200` berhasil · `400` `refreshToken` kosong · `401` refresh token invalid/kedaluwarsa/dicabut → user harus login ulang · `500` kegagalan IS.

---

## `GET /api/v1/auth/userinfo`

Mengembalikan klaim OIDC milik access token pada header `Authorization` (membungkus
`/oauth2/userinfo` milik IS). Hasilnya **di-cache di Redis selama 60 detik** per token, sehingga
pemanggilan berulang dalam rentang itu tidak menambah beban IS.

**Header**

| Header | Wajib | Keterangan |
| --- | --- | --- |
| `Authorization` | ya | `Bearer <accessToken>` |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Userinfo berhasil diambil",
  "data": {
    "sub": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "email": "budi.santoso@swamedia.co.id",
    "name": "Budi Santoso",
    "swaportal_role_id": "3"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T03:25:02.117Z" }
}
```

`data` adalah map klaim apa adanya dari IS — isinya bergantung scope yang diberikan, jadi
perlakukan field selain `sub` sebagai opsional. Untuk data profil karyawan yang lengkap (NIK,
jabatan, unit), pakai [`GET /api/v1/profil-saya`](02-dashboard-dan-self-service.md#modul-profil-saya),
bukan endpoint ini.

**Status:** `200` berhasil · `401` header hilang/salah format, token invalid/kedaluwarsa/dicabut · `500` kegagalan IS.

---

## `POST /api/v1/auth/introspect`

Memeriksa status sebuah token (membungkus `/oauth2/introspect`).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `token` | string | ya | Access atau refresh token yang diperiksa. |
| `tokenTypeHint` | string | tidak | Petunjuk tipe: `"access_token"` atau `"refresh_token"`. |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Introspeksi token berhasil",
  "data": {
    "active": true,
    "scope": "openid profile",
    "username": "budi.santoso",
    "exp": 1784000000,
    "client_id": "swaportal-web"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T03:26:30.510Z" }
}
```

| Field | Keterangan |
| --- | --- |
| `active` | **Satu-satunya field yang dijamin ada.** `false` berarti token kedaluwarsa/dicabut/tidak dikenal. |
| lainnya | `scope`, `username`, `exp`, `client_id`, dst. hanya muncul saat `active: true`, sesuai balasan IS. |

Perhatikan: token mati membalas **`200` dengan `active: false`**, bukan 401. Cek `data.active`,
bukan status HTTP-nya.

**Status:** `200` introspeksi berhasil (baca `active`) · `400` `token` kosong · `500` kegagalan IS.

---

## `POST /api/v1/auth/revoke`

Mencabut access atau refresh token (membungkus `/oauth2/revoke`). Selain mencabut di IS, backend
juga memasukkan token ke **denylist lokal**, sehingga langsung ditolak pada request berikutnya
tanpa menunggu propagasi IS.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `token` | string | ya | Token yang dicabut. |
| `tokenTypeHint` | string | tidak | `"access_token"` atau `"refresh_token"`. |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Token berhasil dicabut",
  "data": null,
  "errors": null,
  "meta": { "timestamp": "2026-07-17T03:28:14.229Z" }
}
```

`data` bernilai `null` — konfirmasinya ada pada `success: true`.

**Status:** `200` berhasil · `400` `token` kosong · `500` kegagalan IS.

---

## `POST /api/v1/auth/logout`

Mengakhiri sesi user di WSO2 IS (membungkus `/oidc/logout`), sekaligus mem-denylist access token
secara lokal bila disertakan.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `idToken` | string | ya | `idToken` dari saat login. Diwajibkan IS untuk mengakhiri sesi. |
| `accessToken` | string | tidak | Access token yang sedang dipakai. **Sangat disarankan dikirim** — inilah yang membuatnya masuk denylist lokal sehingga token tidak bisa dipakai lagi seketika. |

**Contoh request**

```http
POST /api/v1/auth/logout
Content-Type: application/json

{
  "idToken": "eyJ4NXQiOiJOVGRtWmpNNFpEazNOalkwWXpjNU1qW...",
  "accessToken": "eyJ4NXQiOiJOVGRtWmpNNFpEazNOalkwWXpjNU1qW..."
}
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Logout berhasil",
  "data": null,
  "errors": null,
  "meta": { "timestamp": "2026-07-17T03:30:57.640Z" }
}
```

Setelah 200, hapus semua token dari penyimpanan frontend. Bila `accessToken` tidak dikirim, sesi
IS memang berakhir tetapi access token yang beredar tetap lolos validasi JWKS sampai kedaluwarsa
sendiri — karena itu selalu sertakan.

**Status:** `200` berhasil · `400` `idToken` kosong · `500` kegagalan IS.
