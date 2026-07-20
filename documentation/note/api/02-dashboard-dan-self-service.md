# Modul: Dashboard & Self-Service

Lima modul yang datanya melekat pada **pemanggil itu sendiri** (kecuali Dashboard yang publik).
Ciri khas modul self-service: identitas user diambil backend dari access token, **tidak pernah**
dari path/query. Karena itu tidak ada `karyawanId`/`userId`/`subjectId` di parameter mana pun — user
hanya bisa menjangkau datanya sendiri, apa pun rolenya.

Semua modul di sini **tidak dijaga RBAC** (cukup token valid), sebab setiap user berhak atas profil,
akun, menu, dan notifikasinya sendiri.

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.

## Daftar Endpoint

| Method | URL | Fungsi | Auth |
| --- | --- | --- | --- |
| GET | `/api/v1/dashboard/summary` | KPI ringkas untuk landing page | **publik** |
| GET | `/api/v1/profil-saya` | Profil karyawan milik pemanggil (data HR lokal) | Bearer |
| PUT | `/api/v1/profil-saya` | Ubah kontak HR pemanggil (email, no HP) | Bearer |
| GET | `/api/v1/akun-saya` | Identitas login WSO2 IS pemanggil (untuk prefill form edit) | Bearer |
| PUT | `/api/v1/akun-saya` | Ubah data identitas login WSO2 IS pemanggil (email, nama, telepon, organization, country) | Bearer |
| PUT | `/api/v1/akun-saya/password` | Ganti password pemanggil sendiri (terpisah dari update data) | Bearer |
| GET | `/api/v1/menu-saya` | Menu navigasi sesuai role pemanggil | Bearer |
| GET | `/api/v1/notifikasi/unread-count` | Jumlah notifikasi belum dibaca (badge) | Bearer |
| GET | `/api/v1/notifikasi` | Daftar notifikasi pemanggil (berpaginasi) | Bearer |
| PUT | `/api/v1/notifikasi/read-all` | Tandai semua notifikasi sudah dibaca | Bearer |
| PUT | `/api/v1/notifikasi/{id}/read` | Tandai satu notifikasi sudah dibaca | Bearer |

---

# Modul: Dashboard

Ringkasan KPI untuk halaman depan. **Satu-satunya modul bisnis yang publik** — dipanggil sebelum
user punya token (mis. di halaman login), jadi jangan kirim header `Authorization`.

## `GET /api/v1/dashboard/summary`

Mengembalikan tiga angka KPI: Total Proyek, Revenue Bulan Ini, dan Proyek Sedang Dikerjakan.
Tidak ada parameter.

**Contoh request**

```http
GET /api/v1/dashboard/summary
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Ringkasan dashboard berhasil diambil",
  "data": {
    "totalProyek": 137,
    "revenueBulanIni": 1250000000.00,
    "proyekSedangDikerjakan": 24
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T04:02:19.883Z" }
}
```

**Penjelasan field**

| Field | Tipe | Keterangan |
| --- | --- | --- |
| `totalProyek` | int | Jumlah seluruh proyek yang belum dihapus (semua status, semua tahun). |
| `revenueBulanIni` | decimal | Total pencairan tagihan (status `PARSIAL`/`FINAL`) yang **benar-benar cair** pada bulan kalender berjalan. Berbasis kas — tagihan terbit tapi belum cair tidak dihitung. |
| `proyekSedangDikerjakan` | int | Jumlah proyek berstatus `DEAL_KONTRAK` yang `targetSelesai`-nya belum lewat (atau belum diisi). |

**Status:** `200` berhasil · `500` kegagalan server/DB.

---

# Modul: Profil Saya

Profil karyawan milik pemanggil, dipetakan dari klaim `sub` token ke kolom `subject_id` pada tabel
karyawan.

**Prasyarat penting:** user WSO2 IS harus tertaut ke satu baris karyawan (lewat `subjectId` di
[modul Karyawan](03-master-data.md#modul-karyawan)). User yang tidak tertaut akan mendapat **404**
di sini walau tokennya sempurna valid.

**PENTING — `email` di sini BUKAN email login.** Identitas login (username, password, email yang
dipakai untuk autentikasi) sepenuhnya dikelola **WSO2 Identity Server**, bukan backend/database
portal ini (lihat [Manajemen User](04-rbac.md#modul-manajemen-user)). `email` yang dibaca/diubah di
modul ini adalah **kolom kontak HR lokal** (`karyawan.email`) — dipakai untuk keperluan internal
(mis. tujuan notifikasi, tampilan direktori karyawan), dan **sengaja terpisah** dari email login.

Konsekuensinya: mengubah `email` lewat `PUT /api/v1/profil-saya` **tidak mengubah** email/username
yang dipakai user untuk login, dan tidak disinkronkan ke WSO2 IS sama sekali. Beri label yang jelas
di UI (mis. "Email Kontak", bukan "Email Login") supaya user tidak mengira mengubah field ini akan
mengubah kredensial masuknya. Untuk mengubah identitas login, itu dilakukan lewat WSO2 IS sendiri
(My Account portal) atau oleh admin lewat
[`PUT /api/v1/manajemen-user/{subjectId}`](04-rbac.md#put-apiv1manajemen-usersubjectid).

## `GET /api/v1/profil-saya`

Mengambil profil karyawan milik pemanggil. Tidak ada parameter — identitas diambil dari token.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Profil berhasil diambil",
  "data": {
    "id": 42,
    "nik": "SWA-2019-0042",
    "nama": "Budi Santoso",
    "jabatan": { "id": 7, "namaJabatan": "Account Manager", "kategori": "SALES" },
    "unitId": 3,
    "email": "budi.santoso@swamedia.co.id",
    "noHp": "081234567890",
    "tanggalMasuk": "2019-03-01",
    "status": "AKTIF",
    "subjectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "createdAt": "2019-03-01T02:11:00.000Z",
    "updatedAt": "2026-01-14T07:45:22.000Z",
    "createdBy": "system",
    "updatedBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T04:05:41.220Z" }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `nik`, `nama`, `jabatan`, `unitId`, `status` | Dikelola HR lewat modul Karyawan — **read-only di sini**. Tampilkan sebagai teks, bukan input. |
| `jabatan` | Objek hasil join (`id`, `namaJabatan`, `kategori`), selalu ada. |
| `email`, `noHp` | Satu-satunya field yang bisa diubah user sendiri (lihat PUT di bawah). **`email` adalah kontak HR lokal, bukan email login** — lihat catatan di atas. |
| `subjectId` | Id user WSO2 IS yang tertaut. |
| `tanggalMasuk` | `YYYY-MM-DD`, bisa `null`. |

**Status:** `200` berhasil · `401` token invalid/kedaluwarsa · `404` tidak ada karyawan yang tertaut ke `sub` token ini · `500` kegagalan server.

## `PUT /api/v1/profil-saya`

Mengubah informasi kontak pemanggil. **Hanya `email` dan `noHp`** yang bisa diubah — NIK, nama,
jabatan, unit, status, dan `subjectId` tetap dikelola HR lewat modul Karyawan dan memang tidak ada
di bentuk request ini (dikirim pun tidak berpengaruh).

Sekali lagi: `email` di sini **kolom kontak HR lokal**, bukan email/username login WSO2 IS — lihat
catatan di awal bagian ini. Endpoint ini tidak memanggil WSO2 IS sama sekali.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `email` | string | ya | Email baru. |
| `noHp` | string \| null | tidak | No HP baru; kirim `null` (atau hilangkan) untuk mengosongkan. |

**Contoh request**

```http
PUT /api/v1/profil-saya
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "email": "budi.s@swamedia.co.id", "noHp": "081298765432" }
```

**Response:** profil lengkap setelah diperbarui (bentuk sama dengan GET di atas),
`message` = `"Profil berhasil diperbarui"`.

**Status:** `200` berhasil · `400` email kosong/format salah · `401` token invalid · `404` pemanggil tidak tertaut ke karyawan · `409` email sudah dipakai karyawan lain · `500` kegagalan server.

---

# Modul: Akun Saya

Self-service untuk mengubah **identitas login pemanggil di WSO2 Identity Server** — email, nama,
telepon, organization, dan country yang tersimpan di IS itu sendiri. Ini **modul yang berbeda** dari
Profil Saya di atas: Profil Saya mengubah kolom kontak HR lokal (`karyawan.email`/`noHp`) dan tidak
pernah menyentuh IS; Akun Saya mengubah identitas IS-nya langsung lewat SCIM2, dan tidak menyentuh
tabel `karyawan` sama sekali. Beri label yang jelas di UI (mis. dua form/tab terpisah: "Kontak HR" vs
"Akun & Keamanan") supaya user tidak bingung field mana yang mengubah apa.

**Ganti password adalah endpoint terpisah** ([`PUT /api/v1/akun-saya/password`](#put-apiv1akun-sayapassword)),
bukan bagian dari form update data di bawah.

**Target selalu diri sendiri.** `subjectId` yang diubah diambil backend dari klaim `sub` token
pemanggil — tidak ada parameter apa pun untuk menargetkan user lain. Untuk mengubah akun user lain,
itu wewenang Super Admin lewat
[`PUT /api/v1/manajemen-user/{subjectId}/akun`](04-rbac.md#put-apiv1manajemen-usersubjectidakun).

**`swaportal_role_id` (role) sengaja TIDAK ada di endpoint ini.** Mengizinkan user mengubah role-nya
sendiri adalah celah privilege escalation (user bisa menaikkan dirinya jadi Super Admin). Perubahan
role tetap eksklusif admin.

## `GET /api/v1/akun-saya`

Mengambil identitas WSO2 IS milik pemanggil saat ini — dipakai untuk **mengisi form edit** sebelum
user mengubah apa pun. Tidak ada parameter.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Akun berhasil diambil",
  "data": {
    "subjectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "email": "budi.santoso@swamedia.co.id",
    "firstName": "Budi",
    "lastName": "Santoso",
    "telepon": "081234567890",
    "organization": "PT Swamedia Informatika",
    "country": "Indonesia",
    "roleId": 2,
    "groupId": "swamedia_portal_app"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-18T04:08:00.000Z" }
}
```

Bentuk `data` **identik** dengan response `PUT` di bawah — lihat penjelasan field di sana.
`password` tidak pernah ada di response ini (WSO2 IS sendiri tidak mengembalikan password lewat
SCIM2).

**Status:** `200` berhasil · `401` token invalid/kedaluwarsa · `404` akun tidak ditemukan di WSO2 IS
(kasus langka — token valid tapi user sudah dihapus di sisi IS) · `500` kegagalan server (termasuk
WSO2 IS tidak dapat dihubungi).

## `PUT /api/v1/akun-saya`

Mengubah identitas WSO2 IS milik pemanggil. **Semua field opsional** — kirim hanya field yang ingin
diubah; field yang tidak dikirim (atau `null`) tidak disentuh. Minimal harus ada satu field terisi.

**Body** (password **tidak** di sini — lihat [`PUT /api/v1/akun-saya/password`](#put-apiv1akun-sayapassword))

| Field | Tipe | Keterangan |
| --- | --- | --- |
| `email` | string | Email login baru. Divalidasi format email. |
| `firstName` | string | Nama depan baru. Tidak boleh string kosong bila dikirim. |
| `lastName` | string | Nama belakang baru. Tidak boleh string kosong bila dikirim. |
| `telepon` | string | Nomor mobile baru. Maks 20 karakter. Kirim `""` untuk mengosongkan. |
| `organization` | string | Nama organisasi. |
| `country` | string | Negara. |

**Contoh request** (mengubah email dan telepon saja)

```http
PUT /api/v1/akun-saya
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "email": "budi.s@swamedia.co.id", "telepon": "081298765432" }
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Akun berhasil diperbarui",
  "data": {
    "subjectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "email": "budi.s@swamedia.co.id",
    "firstName": "Budi",
    "lastName": "Santoso",
    "telepon": "081298765432",
    "organization": "PT Swamedia Informatika",
    "country": "Indonesia",
    "roleId": 2,
    "groupId": "swamedia_portal_app"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-18T04:12:00.000Z" }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `subjectId` | Id user WSO2 IS yang diubah (selalu milik pemanggil sendiri). |
| `email`, `firstName`, `lastName`, `telepon`, `organization`, `country` | Nilai **terkini** di WSO2 IS setelah update — bukan echo dari request. Bisa `null` bila IS tidak mengembalikan field tersebut. |
| `roleId` | Role portal pemanggil saat ini (read-only, ditampilkan untuk konfirmasi) — **tidak bisa diubah lewat endpoint ini**, `null` bila belum di-assign. |
| `groupId` | Group portal pemanggil (read-only di sini), `null` bila tidak ada. |

**Status:** `200` berhasil · `400` tidak ada field terkirim, format email salah, atau `firstName`/`lastName` kosong · `401` token invalid/kedaluwarsa · `500` kegagalan server (termasuk saat WSO2 IS tidak dapat dihubungi — untuk kasus ini anggap perubahan **kemungkinan besar tidak tersimpan**, jangan tampilkan sebagai sukses).

## `PUT /api/v1/akun-saya/password`

Mengubah **password pemanggil sendiri** di WSO2 IS — operasi terpisah dari update data di atas.
Target selalu diri sendiri (dari klaim `sub` token).

**Body**

| Field | Tipe | Keterangan |
| --- | --- | --- |
| `password` | string | **Wajib.** Password baru. Minimal 6 karakter. |

**Contoh request**

```http
PUT /api/v1/akun-saya/password
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "password": "PasswordBaru123!" }
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Password berhasil diperbarui",
  "data": null,
  "errors": null,
  "meta": { "timestamp": "2026-07-18T04:12:00.000Z" }
}
```

**Status:** `200` berhasil · `400` password < 6 karakter · `401` token invalid/kedaluwarsa · `500` kegagalan server (termasuk saat WSO2 IS tidak dapat dihubungi — anggap perubahan **kemungkinan besar tidak tersimpan**).

---

# Modul: Menu Saya

Sumber kebenaran navigasi sidebar: pohon menu yang **sudah difilter** ke menu yang di-assign ke role
pemanggil dan berstatus `AKTIF`.

Role diambil backend dari klaim `swaportal_role_id` milik pemanggil sendiri — bukan dari parameter —
sehingga user tak mungkin melihat menu role lain.

**Panggil sekali setelah login dan render sidebar dari hasilnya.** Jangan menyusun menu secara
hard-code lalu menyembunyikannya berdasarkan kode role: perubahan Role Menu di layar admin akan
langsung tercermin di sini, tidak di daftar hard-code.

## `GET /api/v1/menu-saya`

Tidak ada parameter.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Menu berhasil diambil",
  "data": [
    {
      "id": 1,
      "parentId": null,
      "kodeMenu": "DASHBOARD",
      "namaMenu": "Dashboard",
      "path": "/dashboard",
      "icon": "layout-dashboard",
      "urutan": 1,
      "status": "AKTIF",
      "children": []
    },
    {
      "id": 10,
      "parentId": null,
      "kodeMenu": "SALES",
      "namaMenu": "Sales Unit",
      "path": null,
      "icon": "trending-up",
      "urutan": 2,
      "status": "AKTIF",
      "children": [
        {
          "id": 11,
          "parentId": 10,
          "kodeMenu": "PROYEK",
          "namaMenu": "Proyek",
          "path": "/sales/proyek",
          "icon": "folder",
          "urutan": 1,
          "status": "AKTIF",
          "children": []
        }
      ]
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T04:10:03.771Z" }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `path` | Route frontend. **`null` berarti node grouping murni** (hanya pembuka submenu) — render sebagai label yang bisa dilipat, jangan dijadikan link. |
| `icon` | Identifier ikon, bisa `null`. Pemetaan ke set ikon diserahkan ke frontend. |
| `urutan` | Urutan tampil di antara sesama sibling. **Data sudah terurut dari backend** — cukup render apa adanya. |
| `children[]` | Anak langsung, rekursif dengan bentuk yang sama. Array kosong untuk daun. |
| `parentId` | `null` untuk node akar. Hierarki sudah tersusun lewat `children`, jadi field ini umumnya tak perlu dipakai frontend. |

Array kosong (`data: []`) itu valid: artinya role pemanggil belum di-assign menu apa pun. Tampilkan
keadaan kosong yang informatif, jangan diperlakukan sebagai error.

**Status:** `200` berhasil · `401` token invalid/kedaluwarsa · `500` kegagalan server.

---

# Modul: Notifikasi

Kotak masuk notifikasi pemanggil, di-scope ke id karyawan miliknya (diambil dari token, sama seperti
Profil Saya). Notifikasi milik user lain tak pernah muncul, terhitung, atau bisa ditandai.

**Read/acknowledge saja** — notifikasi ditulis oleh alur bisnis lain (mis. penugasan proyek), tidak
ada endpoint untuk membuatnya lewat API ini.

## `GET /api/v1/notifikasi/unread-count`

Jumlah notifikasi belum dibaca milik pemanggil, untuk badge di ikon lonceng. Tidak ada parameter.
Endpoint ini jauh lebih ringan daripada mengambil list lalu menghitung sendiri — pakai ini untuk
polling badge.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Jumlah notifikasi belum dibaca berhasil diambil",
  "data": { "unreadCount": 5 },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T04:15:00.000Z" }
}
```

**Status:** `200` berhasil · `401` token invalid · `500` kegagalan server.

## `GET /api/v1/notifikasi`

Daftar notifikasi pemanggil, berpaginasi dan terurut dari yang terbaru.

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `kategori` | string | — | Filter kategori: `PENUGASAN`, `STATUS`, atau `SISTEM`. |
| `is_read` | boolean | — | `false` → hanya yang belum dibaca; `true` → hanya yang sudah. Dihilangkan → semuanya. |
| `page` | int | `1` | Nomor halaman. |
| `limit` | int | `20` | Baris per halaman. |

**Contoh request**

```http
GET /api/v1/notifikasi?is_read=false&kategori=PENUGASAN&page=1&limit=10
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar notifikasi berhasil diambil",
  "data": [
    {
      "id": 812,
      "kategori": "PENUGASAN",
      "judul": "Anda ditugaskan pada proyek baru",
      "pesan": "Anda ditambahkan sebagai Backend Developer pada proyek SWA-IT-2026-014.",
      "refTable": "proyek",
      "refId": 14,
      "linkLabel": "Lihat Proyek",
      "isRead": false,
      "readAt": null,
      "createdAt": "2026-07-16T09:31:12.000Z"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T04:16:44.512Z",
    "pagination": { "page": 1, "limit": 10, "totalItems": 5, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `kategori` | `PENUGASAN` (ditugaskan ke proyek), `STATUS` (perubahan status data), `SISTEM` (pengumuman). Berguna untuk memilih ikon/warna. |
| `judul`, `pesan` | Teks siap tampil. |
| `refTable` + `refId` | Menunjuk baris yang dirujuk notifikasi (mis. `"proyek"` + `14`). Dipakai frontend untuk menyusun deep link. Keduanya bisa `null` — pada kasus itu jangan render link. |
| `linkLabel` | Label tombol/link yang disarankan (mis. `"Lihat Proyek"`). Bisa `null`. |
| `isRead` | Sudah dibaca atau belum. |
| `readAt` | Waktu dibaca; `null` selama `isRead: false`. |

**Status:** `200` berhasil · `400` `kategori` di luar enum atau `is_read` bukan boolean · `401` token invalid · `500` kegagalan server.

## `PUT /api/v1/notifikasi/read-all`

Menandai **semua** notifikasi pemanggil yang belum dibaca menjadi sudah dibaca. Tanpa parameter dan
tanpa body.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Semua notifikasi ditandai sudah dibaca",
  "data": null,
  "errors": null,
  "meta": { "timestamp": "2026-07-17T04:18:20.005Z" }
}
```

`data` bernilai `null` — setelah 200, refresh list dan `unread-count`.

**Status:** `200` berhasil (termasuk saat tidak ada yang belum dibaca) · `401` token invalid · `500` kegagalan server.

## `PUT /api/v1/notifikasi/{id}/read`

Menandai satu notifikasi milik pemanggil sebagai sudah dibaca.

**Path parameter**

| Parameter | Tipe | Keterangan |
| --- | --- | --- |
| `id` | int | Id notifikasi. |

**Contoh request**

```http
PUT /api/v1/notifikasi/812/read
Authorization: Bearer <accessToken>
```

**Response:** `data: null`, `message` = `"Notifikasi ditandai sudah dibaca"`. Tanpa body request.

**Status**

| Status | Keterangan |
| --- | --- |
| `200` | Berhasil (idempoten — menandai yang sudah dibaca tetap 200). |
| `401` | Token invalid. |
| `404` | Notifikasi tidak ada, **atau milik user lain**. Kepemilikan sengaja dilaporkan sebagai 404, bukan 403, agar keberadaan notifikasi orang lain tidak bocor. |
| `500` | Kegagalan server. |
