# Swamedia Project Website Portal — Backend

Backend RESTful API untuk **Swamedia Project Website Portal**, dibangun dengan
[Ballerina](https://ballerina.io/) `2201.13.4` (Swan Lake Update 13). Backend ini berperan
sebagai **BFF (Backend for Frontend)** di depan WSO2 Identity Server untuk autentikasi, dan
sebagai REST API penuh (CRUD) untuk seluruh data operasional portal (sales, keuangan, RBAC,
e-office, dsb) yang disimpan di PostgreSQL.

## Tech Stack

| Komponen | Teknologi |
| --- | --- |
| Bahasa & runtime | Ballerina `2201.13.4` (berjalan di atas OpenJDK 21) |
| Database utama | PostgreSQL 16 |
| Cache | Redis 7 (cache generik: userinfo, invalidasi role/permission, dsb) |
| Autentikasi | WSO2 Identity Server (OAuth2 / OIDC), akses token divalidasi via JWKS |
| Kontainerisasi | Docker + Docker Compose |

## Arsitektur

Pola layer yang dipakai di seluruh project:

```
Client (frontend)
  |
  v
HTTP Resource (main.bal)      -> menerima request, membungkus response ke ApiResponse standar
  |
  v
Service (modules/services)    -> business rule & validasi, mengembalikan models:AppError untuk error domain
  |
  v
Repository (modules/repositories) -> satu-satunya layer yang bicara ke Postgres/Redis/WSO2 IS
  |
  v
PostgreSQL / Redis / WSO2 IS
```

Struktur folder:

```
swamedia_portal_be/
|-- main.bal                 # HTTP listener + seluruh service/resource REST API
|-- Ballerina.toml            # metadata package (org, versi, distribusi Ballerina)
|-- Dependencies.toml         # lockfile dependency (untuk build reproducible)
|-- Dockerfile                # multi-stage build image production
|-- docker-compose.yml        # stack lengkap: postgres + redis + app
|-- Config.toml               # (gitignored) config lokal untuk `bal run`
|-- Config.docker.toml.example# template config untuk `docker compose`
`-- modules/
    |-- config/                # seluruh nilai configurable (port, DB, Redis, WSO2 IS, CORS)
    |-- models/                # semua type: request/response body, entity, ApiResponse, AppError
    |-- repositories/          # akses data: query Postgres, cache Redis, panggilan ke WSO2 IS
    |-- services/              # business logic + validasi per modul
    `-- utils/                 # helper response envelope, JWT/token helper, denylist token
```

Setiap response (sukses maupun error) dibungkus dalam envelope standar yang sama:

```json
{
  "success": true,
  "message": "Daftar unit berhasil diambil",
  "data": [ ... ],
  "errors": null,
  "meta": { "timestamp": "...", "pagination": { "page": 1, "limit": 20, "totalItems": 13, "totalPages": 1 } }
}
```

Detail lengkap standar response (mapping HTTP status ↔ `errors.code`, contoh sukses/error/
paginasi) ada di bagian "API Response Standard" pada `documentation/note/README.md`.

## Fitur / Modul yang Sudah Dibangun

### Autentikasi (`/api/v1/auth`) — BFF di depan WSO2 IS
Frontend tidak pernah bicara langsung ke WSO2 IS — semua URL, client credential, dan flowId
tetap di backend.

| Endpoint | Fungsi |
| --- | --- |
| `POST /api/v1/auth/init` | Mulai flow login (opsional, bisa langsung pakai `/login`) |
| `POST /api/v1/auth/login` | Login username/password (menjalankan init → authenticate → token exchange sekaligus) |
| `POST /api/v1/auth/token` | Tukar authorization code menjadi token |
| `POST /api/v1/auth/refresh` | Refresh access token |
| `GET  /api/v1/auth/userinfo` | Klaim user dari access token (di-cache di Redis 60 detik) |
| `POST /api/v1/auth/introspect` | Cek status token |
| `POST /api/v1/auth/revoke` | Cabut token (+ denylist lokal) |
| `POST /api/v1/auth/logout` | Logout dari WSO2 IS (+ denylist lokal) |

### Dashboard (`/api/v1/dashboard`) — publik, sebelum login
`GET /api/v1/dashboard/summary` — Total Proyek, Revenue Bulan Ini, Proyek Sedang Dikerjakan.

### Master Data — CRUD penuh (list berpaginasi + detail + create + update + soft/hard delete)

| Modul | Endpoint dasar |
| --- | --- |
| Unit Organisasi (+ tree hierarki) | `/api/v1/master/units` |
| Industri | `/api/v1/master/industries` |
| Tags (label Proyek) | `/api/v1/master/tags` |
| Resource Tags (label Resource Unit) | `/api/v1/master/resource-tags` |
| Kategori Surat (DR-01..DR-09) | `/api/v1/master/kategori-surat` |
| Jabatan (`jabatan_master`) | `/api/v1/master/jabatan` — **read-only**, sumber dropdown |
| Karyawan (+ dropdown ringan) | `/api/v1/master/karyawan` |
| Customer | `/api/v1/master/customers` |
| Contact (narahubung customer) | `/api/v1/master/contacts` |
| Kategori Finansial Keluar | `/api/v1/master/kategori-finansial-keluar` — dipakai Pembayaran & Pengeluaran; delete fisik (ditolak bila masih dirujuk) |
| Resource Unit | `/api/v1/master/resource-unit` — 1 baris per unit (headcount/kapasitas + lead) |

### RBAC — Role, Menu, Permission (skema v2.1)
Role/Permission/Menu dikelola penuh di database ini (bukan lagi di WSO2 IS — IS hanya
menyimpan referensi `swaportal_role_id`).

| Modul | Endpoint dasar | Catatan |
| --- | --- | --- |
| Role | `/api/v1/master/roles` | CRUD penuh; delete = hard delete (cascade bersihkan role_permission/role_menu) |
| Menu (navigasi, hierarkis) | `/api/v1/master/menu` (+ `/tree`) | CRUD penuh |
| Modul (daftar modul aplikasi) | `/api/v1/master/modul` | **read-only**, master tetap |
| Role Permission (matriks role × modul) | `/api/v1/master/role-permissions/{roleId}` | `GET` ambil matriks penuh, `PUT` simpan seluruh matriks sekaligus |
| Role Menu (assignment menu per role) | `/api/v1/master/role-menus/{roleId}` | `GET` ambil tree + flag assigned, `PUT` simpan seluruh assignment sekaligus |

Menyimpan Role Permission/Role Menu otomatis meng-invalidate cache Redis
(`role:{id}:permissions` / `role:{id}:menu`) yang dipakai middleware enforcement (lihat bagian
berikut) saat mengecek hak akses. Karena di-invalidate langsung, perubahan matriks langsung
berlaku pada request berikutnya, tanpa menunggu TTL.

### Gerbang Akses Aplikasi (`swaportal_group_id`)

Hanya user WSO2 IS yang di-provision ke aplikasi portal ini yang boleh memanggil API. WSO2
menyisipkan keanggotaan aplikasi ke setiap access/id token sebagai custom claim
`swaportal_group_id` (bernilai `swamedia_portal_app`). Gerbang ini di-enforce di **dua** titik yang
saling melengkapi:

1. **Deklaratif, per-request** — setiap service ter-proteksi menambahkan `scopeKey` +
   `scopes` pada blok `auth` `@http:ServiceConfig`-nya, sehingga JWKS auth Ballerina menolak dengan
   **403** (sudah terverifikasi tanda tangan) sebelum resource jalan bila token tidak membawa grup:

   ```ballerina
   auth: [{
       jwtValidatorConfig: { issuer: ..., audience: ..., scopeKey: config:appGroupClaim, ... },
       scopes: [config:appGroupId]
   }]
   ```

2. **Saat login** — `services:buildLoginResponse` menolak sign-in lebih awal dengan pesan jelas
   (`403 "Akun Anda tidak memiliki akses ke portal ini"`) bila id_token tidak membawa grup, alih-alih
   membiarkan setiap panggilan berikutnya gagal 403.

Keduanya `configurable` (`appGroupClaim` / `appGroupId`) supaya deployment/aplikasi lain bisa
mengarahkan ulang nama claim + nilainya lewat `Config.toml`.

### Middleware — Enforcement Perizinan (RBAC)

Autentikasi (siapa Anda) sudah dijaga oleh JWKS + denylist token. **Otorisasi** (boleh melakukan
apa) dijaga oleh `PermissionInterceptor` (di `main.bal`), sebuah request interceptor yang dipasang
per-service — persis pola `createInterceptors()` yang sama dengan denylist token:

```ballerina
public function createInterceptors() returns http:Interceptor[] =>
    [tokenDenylistInterceptor, new PermissionInterceptor("TAGIHAN")];
```

Alur setiap request (di `services:requirePermission`, sesuai catatan implementasi skema #7):

1. Baca `swaportal_role_id` dari userinfo pemanggil (memakai cache userinfo 60 detik yang sudah ada).
2. Ambil matriks `role_permission` role tsb secara **cache-aside** dari Redis
   (`role:{id}:permissions`); miss/Redis mati → fallback ke DB lalu isi ulang cache.
3. Petakan **HTTP method + path → aksi**, lalu izinkan hanya bila bit-nya `true`:

   | Trigger | Aksi | Kolom `role_permission` |
   | --- | --- | --- |
   | `GET` / `HEAD` | read | `can_read` |
   | `POST` | create | `can_create` |
   | `PUT` / `PATCH` | update | `can_update` |
   | `DELETE` | delete | `can_delete` |
   | segmen path `approve` / `reject` | approve | `can_approve` |
   | segmen path `export` | export | `can_export` |

   Bila tidak berhak → **403 FORBIDDEN** (envelope error standar), resource tidak pernah jalan.

Sub-resource yang moduling-nya berbeda dari service induknya diarahkan lewat argumen kedua
(segmen path → kode modul), mis. Pencairan yang bersarang di bawah Tagihan, dan Team Member di
bawah Proyek:

```ballerina
new PermissionInterceptor("TAGIHAN", {"pencairan": "PENCAIRAN"})
new PermissionInterceptor("PROYEK",  {"team-member": "TEAM_MEMBER"})
new PermissionInterceptor("REVENUE_UNIT", {"tw": "REVENUE_UNIT_TW"})
```

**Master switch:** `permissionEnforcementEnabled` (default `true`, secure-by-default). Selama masa
transisi — sebelum user WSO2 IS punya custom attribute `swaportal_role_id` (di-provision via SCIM2,
catatan skema #2) — set `false` di `Config.toml` supaya token yang JWKS-valid boleh mengakses
semua endpoint ter-gate. Dengan enforcement `true` tapi role belum di-set, pemanggil menerima 403
("Akun belum memiliki role").

**Service yang sengaja TIDAK di-gate** (tetap hanya JWKS + denylist):

| Service | Alasan |
| --- | --- |
| `/api/v1/profil-saya`, `/api/v1/akun-saya`, `/api/v1/notifikasi`, `/api/v1/menu-saya` | Self-service; sudah di-scope ke pemanggil sendiri (via `subject_id` / role di token), harus tetap bisa diakses semua role — tetap dijaga gerbang grup aplikasi + JWKS |
| `/api/v1/master/tags`, `/api/v1/master/jabatan` | Data referensi bersama tanpa baris `modul` tersendiri (label proyek / dropdown jabatan) |
| `/api/v1/business/kontrak-biasa` | Belum ada baris `KONTRAK_BIASA` di master `modul` — menunggu keputusan penempatan di matriks |
| `/api/v1/auth/*`, `/api/v1/dashboard/summary` | Publik / pra-login secara desain |

**Yang MASIH ditunda (belum di-enforce):**

- **Scope baris (`UNIT_SENDIRI`)** — kolom `scope` sudah dibaca & di-cache, tapi middleware ini
  baru menjaga verb CRUD/approve/export secara kasar. Penyaringan baris list/detail ke unit
  pemanggil menyentuh setiap query repository dan sengaja jadi layer terpisah berikutnya
  (`TODO(rbac-scope)`).
- **Cek unit "Direktur Utama" untuk approval** (catatan skema #8) — middleware baru memeriksa bit
  `can_approve` level-role; validasi `karyawan.unit_id = Direktur Utama` tetap concern service-layer
  yang belum di-wire.
- **Endpoint export (`can_export`)** — bit izin sudah ada di matriks, tapi endpoint Export Excel/PDF
  itu sendiri belum dibangun.

### Sales Unit (Proyek)

| Modul | Endpoint dasar | Catatan |
| --- | --- | --- |
| Proyek | `/api/v1/business/proyek` | CRUD penuh + dropdown ringan (`/dropdown`) + riwayat status (`/{id}/log-status`) |
| Kontrak Payung | `/api/v1/business/kontrak-payung` | CRUD penuh + harga per role inline (`hargaRole`, replace-on-update) + dropdown (`/dropdown`); `noKontrakPayung` unik, delete ditolak bila masih dipakai proyek/kontrak biasa |
| Kontrak Biasa | `/api/v1/business/kontrak-biasa` | CRUD penuh + dropdown (`/dropdown`); bisa berdiri sendiri atau di bawah kontrak payung (customer sama), `noKontrakBiasa` unik, delete ditolak bila masih dipakai proyek |
| Unit Share | `/api/v1/business/proyek/{proyekId}/unit-share` | CRUD pembagian nilai proyek antar unit; total share tidak boleh melebihi `nilaiProyek`, satu unit unik per proyek |
| Team Member | `/api/v1/business/proyek/{proyekId}/team-member` | CRUD penugasan karyawan ke proyek per periode (role, tgl_mulai/selesai, bobot); status undangan email dikontrol backend |
| Proyek Tags | `/api/v1/business/proyek/{proyekId}/tags` | Kelola tag proyek (M2M): `GET` list, `PUT` ganti seluruh set, `POST /{tagId}` pasang satu (idempoten), `DELETE /{tagId}` lepas satu |
| Target Revenue Unit | `/api/v1/business/target-revenue-unit` | CRUD target revenue per unit per tahun (4 triwulan); unik per (unit, tahun); delete fisik (tabel tanpa soft-delete) |
| Revenue Unit (laporan) | `/api/v1/business/revenue-unit` | Read-only: `GET` laporan target vs realisasi per unit (4 TW + total + %), `GET /tw?triwulan=N` per triwulan, `GET /chart` data chart 4 titik |
| Target Sales Unit | `/api/v1/business/target-sales-unit` | Kembaran Target Revenue Unit untuk target **sales/deal** (tabel `target_sales_unit`); CRUD, unik per (unit, tahun), delete fisik |
| Sales Matrix / Pencapaian Sales Unit (laporan) | `/api/v1/business/sales-matrix` | Read-only: target sales vs realisasi **deal-basis** (`v_realisasi_sales_tw` = `nilai_bersih` proyek DEAL_KONTRAK); `GET` per unit (4 TW + total + %), `GET /tw`, `GET /chart` |

`kodeProyek` digenerate backend (format `{prefix}-{kodeUnit}-{tahun}-{urutan}`, mis.
"PRJ-MKT-2026-001") secara atomik per (unit, tahun) — pola yang sama persis dengan generate
nomor surat. `unitId`/`tahun` immutable setelah dibuat (keduanya tertanam di kodeProyek).
Setiap perubahan `status` (termasuk status awal saat create) otomatis dicatat ke `log_status`,
dan saat pertama kali transisi ke `DEAL_KONTRAK`, `tanggalDeal` otomatis diisi tanggal hari itu
(hanya jika belum pernah terisi) — sesuai catatan implementasi pada skema database.

Kontrak Payung adalah entitas bisnis tersendiri (dirujuk oleh Proyek & Kontrak Biasa). Harga per
project-role (`kontrak_payung_harga_role`, tipe `PER_BULAN`/`PER_PROJECT`) dikelola inline bersama
kontraknya: dikirim di field `hargaRole` saat create, dan pada update seluruh set harga di-*replace*
hanya bila field `hargaRole` disertakan (bila diabaikan, harga lama dipertahankan). Delete bersifat
soft-delete dan ditolak (`409`) selama masih ada proyek/kontrak biasa aktif yang merujuknya. Helper
`kontrakPayungCustomerId`/`kontrakBiasaCustomerId` (validasi kepemilikan customer saat pilih
kontrak di form Proyek) sudah dipindah dari proyek_repository ke modul kontrak masing-masing —
menuntaskan seluruh `TODO(kontrak-*-module)` yang tersisa. Kontrak Biasa lebih sederhana dari
Kontrak Payung: tanpa tabel anak dan `noKontrakBiasa` diisi manual (bukan digenerate).

Unit Share, Team Member, dan Proyek Tags adalah sub-resource dari sebuah proyek — `proyekId`
selalu diambil dari path, dan setiap id anak di-scope ke proyek induknya (akses lintas-proyek
dibalas `404`, tidak pernah bocor). Referensi FK (unit, karyawan, project role, tag) divalidasi
sebelum menyimpan. Kolom junction `proyek_tags` tanpa audit sehingga operasi tag tidak mencatat
`created_by/updated_by` (tetap dilindungi JWT). Fitur pengiriman email undangan team member belum
dibangun — `undanganStatus` default `BELUM_DIKIRIM` dan tidak diterima dari payload.

**Revenue Unit** terdiri dari satu tabel tersimpan (`target_revenue_unit` — target per unit per
tahun, dipecah 4 triwulan, CRUD penuh) dan tiga laporan read-only yang menggabungkannya dengan
view `v_realisasi_revenue_tw` (realisasi cash-basis: `pencairan_tagihan` berstatus PARSIAL/FINAL,
dikelompokkan per unit proyek & triwulan pencairan). `revenue-unit` = laporan target vs realisasi
per unit (semua TW + total + `pencapaianPersen`), `revenue-unit/tw?triwulan=N` = versi satu
triwulan, `revenue-unit/chart` = 4 titik (TW1–TW4) target vs realisasi untuk grafik (agregat semua
unit, atau satu unit bila `unit_id` diisi). `tahun` default tahun berjalan bila tidak diisi.

### Finansial

| Modul | Endpoint dasar | Catatan |
| --- | --- | --- |
| Tagihan (+ riwayat status) | `/api/v1/finance/tagihan` | CRUD; `noTagihan` unik; perubahan `statusAktif` dicatat ke `status_tagihan` (`/{id}/status-history`); `totalPencairan` dihitung |
| Pencairan Tagihan | `/api/v1/finance/tagihan/{tagihanId}/pencairan` | CRUD sub-resource (realisasi cash-in bertahap); total non-DIBATALKAN tidak boleh melebihi `nilaiTagihan` |
| Pembayaran | `/api/v1/finance/pembayaran` | CRUD + approval (`PUT /{id}/approve`, `/reject`); cash-out terikat proyek |
| Pengeluaran Perusahaan | `/api/v1/finance/pengeluaran-perusahaan` | CRUD + approval; cash-out operasional terikat unit |
| Saldo Awal Kas (+ Posisi Kas) | `/api/v1/finance/saldo-awal-kas` | Append-only (list/detail/create, tanpa update/delete) + `GET /posisi-kas` (dari view `v_posisi_kas`) |
| Cashflow (laporan) | `/api/v1/business/cashflow` | Read-only per tahun (company-wide): `GET` 12 baris bulanan inflow/outflow/net + total + posisi kas terkini, `GET /chart` 12 titik inflow-vs-outflow. Inflow = pencairan `PARSIAL`/`FINAL`; outflow = pembayaran + pengeluaran `APPROVED` ber-`tanggalRealisasi` |

**Alur approval Pembayaran/Pengeluaran** memakai status `PENGAJUAN → APPROVED / REJECTED`. Edit
hanya diizinkan selama `PENGAJUAN`/`REJECTED` — mengedit baris `REJECTED` otomatis membukanya
kembali ke `PENGAJUAN` (catatan implementasi skema #5); baris `APPROVED` terkunci. `approve`/`reject`
hanya berlaku pada baris `PENGAJUAN`, mencatat `approvedBy` dari klaim `sub` token, dan `approve`
bisa sekalian mengisi `tanggalRealisasi`.

> ⚠️ **Otorisasi approval belum diterapkan.** Catatan implementasi skema #8 menyatakan hanya
> karyawan ber-unit "Direktur Utama" yang punya `role_permission.can_approve` boleh meng-approve —
> tetapi **role-based authorization belum ada sama sekali di codebase ini** (lihat catatan sama di
> `karyawan_service`). Membangun cek hanya di modul ini justru memberi rasa aman palsu selagi modul
> lain terbuka, jadi untuk saat ini yang ditegakkan hanya **state machine**-nya; siapa yang boleh
> approve belum dibatasi. Menunggu keputusan/arsitektur role-middleware.

**Posisi Kas** (`v_posisi_kas`) berpangkal pada saldo awal kas terbaru, lalu menambah inflow
terealisasi (pencairan `PARSIAL`/`FINAL` pada/ setelah tanggal saldo) dan mengurangi outflow
terealisasi (pembayaran + pengeluaran `APPROVED` yang punya `tanggalRealisasi` pada/setelah tanggal
saldo). Field turunan saldo bernilai `null` bila belum ada baris saldo awal kas.

### e-Office

| Modul | Endpoint dasar | Catatan |
| --- | --- | --- |
| Daftar Surat (`nomor_surat`) | `/api/v1/business/daftar-surat` | CRUD + preview nomor surat; nomor digenerate atomik (advisory lock) per (kategori, tahun); delete = pembatalan (wajib alasan), bukan hapus fisik |

### Pengaturan (self-service)

| Modul | Endpoint dasar | Catatan |
| --- | --- | --- |
| Profil Saya | `/api/v1/profil-saya` | `GET` profil karyawan milik sendiri, `PUT` update kontak HR lokal (`email`/`noHp` saja) |
| Akun Saya | `/api/v1/akun-saya` | `GET` identitas WSO2 IS milik pemanggil (prefill form), `PUT` update data (`email`/`firstName`/`lastName`/`telepon`/`organization`/`country`), `PUT /password` ganti password (terpisah dari update data); role **tidak** bisa diubah di sini — lihat catatan di bawah |
| Menu Saya | `/api/v1/menu-saya` | `GET` pohon menu navigasi terfilter sesuai role pemanggil (hanya menu yang di-assign ke role & AKTIF); role diambil dari claim `swaportal_role_id`, cache-aside `role:{id}:menu` |
| Notifikasi | `/api/v1/notifikasi` | `GET` list (filter `kategori`/`is_read`) + `/unread-count`; `PUT /{id}/read` tandai satu, `PUT /read-all` tandai semua |
| Konfigurasi Sistem | `/api/v1/konfigurasi-sistem` | `GET` list (registry `sys_config` yang sudah di-seed) + `GET /{key}`, `PUT /{key}` ubah `value` saja — tidak ada create/delete, set key tetap |
| Manajemen User | `/api/v1/manajemen-user` | `GET` list/detail (mirror `user_cache`, LEFT JOIN karyawan) + **operasi tulis via SCIM2**: `POST` buat user, `PUT /{subjectId}` ubah profil, `PUT /{subjectId}/role` set role, `PUT /{subjectId}/status` enable/disable, `GET /{subjectId}/akun` + `PUT /{subjectId}/akun` Super Admin lihat/ubah data akun user lain (`firstName`/`lastName`/`organization`/`country`/`email`/`telepon`/`roleId`/`groupId`), `PUT /{subjectId}/password` reset password (terpisah) — lihat catatan di bawah |

Ketiga modul self-service di atas (Profil Saya, Akun Saya, Notifikasi) **tidak menerima id dari
path/query** — target selalu di-resolve dari klaim `sub` di access token, jadi seorang user hanya
bisa pernah melihat/mengubah datanya sendiri. Profil Saya me-resolve lewat `karyawan.subject_id`
(membalas `404` bila belum ditautkan admin); Akun Saya memakai `sub` langsung sebagai `subjectId`
WSO2 IS (tidak butuh baris karyawan tertaut sama sekali). Data identitas HR (nik/nama/jabatan/unit/
status) tetap dikelola admin lewat `/api/v1/master/karyawan` — Profil Saya sengaja hanya mengizinkan
ubah kontak. Notifikasi bersifat read/acknowledge-only dari sisi API: baris notifikasi ditulis oleh
proses bisnis lain (alur pembuat notifikasi belum dibangun di iterasi ini), bukan dibuat lewat
endpoint ini.

**Akun Saya** vs **Profil Saya**: dua modul yang mirip namanya tapi menulis ke tempat berbeda.
Profil Saya hanya menulis ke tabel `karyawan` lokal (kontak HR) dan tidak pernah memanggil WSO2 IS.
Akun Saya menulis **langsung ke WSO2 IS via SCIM2** (identitas login sesungguhnya: email, nama,
telepon, organization, country) dan tidak menyentuh tabel `karyawan` sama sekali. **Ganti password
adalah operasi terpisah** (`PUT /api/v1/akun-saya/password`), bukan bagian dari form update data —
sama seperti sisi admin (`PUT /{subjectId}/password`). `swaportal_role_id` sengaja **tidak** ada di
Akun Saya — mengizinkan user self-service mengganti role sendiri adalah celah privilege escalation;
role tetap eksklusif diubah admin (`/role` atau `/akun` di Manajemen User).

**Konfigurasi Sistem** membungkus tabel `sys_config` (registry key-value global, PK-nya adalah
`key` itu sendiri, bukan id numerik) yang sudah di-seed dan dipakai langsung oleh banyak bagian
kode (mis. `prefix_kode_proyek`, `prefix_nomor_surat`). Hanya `value` yang bisa diubah lewat API
— `deskripsi` tetap label sistem, dan tidak ada endpoint untuk menambah/menghapus key baru karena
setiap key yang ada memang dirujuk secara eksplisit oleh nama di kode.

**Manajemen User** membaca dari `user_cache` (mirror lokal user WSO2 IS, di-LEFT JOIN ke `karyawan`
via `subject_id`), tetapi seluruh **operasi tulis** dijalankan lewat **SCIM2 API WSO2 IS**
(`repositories/scim2_repository.bal`), **bukan** langsung ke database ini.

**Satu mekanisme auth untuk semua operasi SCIM2:** akun **Super Admin IS sungguhan** (HTTP Basic,
`config:scimAdminUsername`/`scimAdminPassword`) — dipakai `POST` buat user, `PUT /{subjectId}` ubah
profil (nama+email), `PUT /{subjectId}/role` set role, `PUT /{subjectId}/status` enable/disable,
`PUT /{subjectId}/akun` (admin ubah **data** akun user lain), `PUT /{subjectId}/password` (admin
**reset password** user lain), plus endpoint self-service [Akun Saya](#pengaturan-self-service)
(`PUT /api/v1/akun-saya` dan `PUT /api/v1/akun-saya/password`). Kredensial ini **tidak pernah**
hardcode di kode; hanya di-set lewat `Config.toml`/`Config.docker.toml` lokal (gitignored).

> ⚠️ **Kenapa bukan token app-level?** Desain awal memakai DUA kredensial: token `client_credentials`
> (`clientId`/`clientSecret`) untuk operasi "sederhana" (create/update-profil/role/status), dan Super
> Admin Basic hanya untuk `/akun`+`/password`. Di deployment ini jalur token app-level ditolak WSO2 IS
> dengan `403 "Operation is not permitted. You do not have permissions to make this request."` — model
> **API Authorization** WSO2 IS 7.x tidak pernah meng-authorize OAuth2 app tersebut ke SCIM2 Users API
> (perlu di-setup manual di Console → Applications → app → tab **API Authorization**, menambahkan SCIM2
> Users API + scope `internal_user_mgt_*`). Karena hanya akun Super Admin yang terbukti jalan (semua
> contoh di `URL-Doc-IS7.md` pakai Basic Auth Super Admin), seluruh operasi tulis SCIM2 dikonsolidasi ke
> kredensial itu supaya modul ini langsung bisa dipakai tanpa butuh akses Console WSO2 IS. Kalau
> nantinya app di-authorize lewat Console, jalur `client_credentials` bisa dipisah kembali untuk operasi
> rutin non-sensitif.

Semua panggilan memanggil `/scim2/Users`; atribut `swaportal_role_id` ditulis di bawah URN
`config:scimRoleClaimSchema`. Setiap tulis yang sukses lalu **write-through** di-mirror ke `user_cache`
(via `upsertUserCache`) supaya sisi baca langsung sinkron tanpa menunggu job reconciliation.

**Sync tambahan saat login** — setiap login berhasil (`POST /api/v1/auth/login` maupun
`POST /api/v1/auth/token`, keduanya lewat `services:exchangeToken`) juga men-mirror klaim id_token
(`sub`/`name`/`email`) ke `user_cache` lewat `syncUserCacheFromLogin`
(`user_cache_service.bal`) — best-effort, gagal di-log saja, tidak pernah menggagalkan login. Baris
yang datanya **sudah identik** (nama/email/status) di-skip, tidak di-`UPDATE` ulang, supaya login
berulang tanpa perubahan tidak percuma menulis `last_synced_at`. `POST /api/v1/auth/refresh`
**sengaja tidak** memicu sync ini — refresh token adalah perpanjangan sesi diam-diam, bukan login
baru, jadi tidak ditambahi round-trip DB di setiap refresh.

> ⚠️ **Jalur SCIM2 belum terverifikasi end-to-end.** Berbeda dari modul lain (yang diverifikasi ke
> Postgres nyata), jalur tulis SCIM2 hanya bisa dikompilasi & di-review — memverifikasinya butuh
> WSO2 IS hidup dengan SCIM2 aktif dan app yang diizinkan scope user-management. Bentuk request
> mengikuti spec SCIM2 + ekstensi custom-claim WSO2; URN skema `swaportal_role_id` bersifat
> deployment-specific (dibuat configurable). Job reconciliation `user_cache` juga masih belum ada.

### Audit Log (read-only)

| Modul | Endpoint dasar | Catatan |
| --- | --- | --- |
| Audit Log | `/api/v1/audit-log` | Read-only; `GET` list (filter `table_name`/`aksi`/`aktor`/`record_id`/`date_from`/`date_to`) + `GET /{id}` |

Tabel `audit_log` bersifat append-only dan ditulis secara internal oleh service lain (mis.
`nomor_surat_service` saat pembatalan surat, lewat `repositories:insertAuditLog`) — modul ini
tidak punya endpoint create/update/delete. Kolom `perubahan` disimpan sebagai teks berisi string
JSON (bukan kolom `jsonb`), sehingga API men-decode-nya kembali menjadi objek JSON terstruktur
sebelum dikembalikan ke client.

Semua endpoint di atas (kecuali `/api/v1/auth/*` dan `/api/v1/dashboard/summary`) dilindungi
JWT access token (validasi signature via JWKS WSO2 IS, otomatis 401 jika token invalid/kosong)
dan tambahan pengecekan token denylist (token yang sudah di-revoke/logout langsung ditolak
walau belum expired). Di atas itu, sebagian besar service kini juga di-gate RBAC per-role lewat
`PermissionInterceptor` — lihat bagian **Middleware — Enforcement Perizinan (RBAC)** di atas.

## Modul / Fitur yang Belum Dibangun

Sisa yang belum dibangun setelah iterasi Resource Unit / Cashflow / Target Sales Unit / Kategori
Finansial Keluar / Sales Matrix / Manajemen User (writes). Semuanya kini bersifat **alur/pekerjaan
lintas-modul**, bukan modul CRUD tersendiri:

- **RBAC scope (`UNIT_SENDIRI`) & cek unit Direktur Utama** — penyaringan baris per unit dan
  validasi approver, ditunda (detail di bagian Middleware di atas).
- **Endpoint Export Excel/PDF** (`can_export`) — bit izin sudah ada di matriks, endpoint-nya belum.
- **Alur pembuat (producer) Notifikasi** — inbox sudah bisa dibaca/di-acknowledge, tapi proses
  bisnis yang menulis baris notifikasi belum ada.
- **Job reconciliation `user_cache`** — sinkronisasi periodik dari WSO2 IS
  (`sys_config.jadwal_reconciliation`) yang mengisi `user_cache`. Manajemen User sudah write-through
  ke cache saat menulis lewat SCIM2, tapi job rekonsiliasi berkala penuhnya belum dibangun.
- **Verifikasi live jalur SCIM2** — modul Manajemen User (writes) sudah dikompilasi & di-review,
  tetapi perlu diuji terhadap WSO2 IS nyata (lihat ⚠️ di bagian Pengaturan).

## Prasyarat

Pilih salah satu cara menjalankan di bawah — **Docker** (paling cepat, tidak perlu install
Ballerina/Postgres/Redis manual) atau **langsung dengan `bal run`** (untuk development harian
dengan hot-reload lebih cepat).

Yang selalu dibutuhkan di kedua cara:
- Kredensial aplikasi OAuth2 di WSO2 Identity Server (`clientId`, `clientSecret`, `redirectUri`).

## Cara 1 — Menjalankan dengan Docker (direkomendasikan)

Menjalankan seluruh stack (PostgreSQL + Redis + backend) sekaligus, termasuk otomatis
membuat skema database dari `documentation/database/swamedia_portal_schema_v2.1.sql` saat
volume Postgres masih kosong.

Prasyarat: [Docker](https://docs.docker.com/get-docker/) + Docker Compose.

1. Salin template config dan isi kredensial asli:

   ```bash
   cp Config.docker.toml.example Config.docker.toml
   cp .env.example .env
   ```

   - Di `Config.docker.toml`: isi `clientId`, `clientSecret`, `dbPassword` (bebas, ini password
     Postgres milik container sendiri). **Jangan ubah** `dbHost`/`redisHost` — keduanya sudah
     diarahkan ke nama service Docker Compose (`postgres`/`redis`), bukan `localhost`.
   - Di `.env`: isi `POSTGRES_PASSWORD` dengan **nilai yang sama persis** dengan `dbPassword`
     di atas (dipakai untuk inisialisasi container Postgres).

2. Build & jalankan:

   ```bash
   docker compose up -d --build
   ```

3. Cek semua container sehat:

   ```bash
   docker compose ps
   ```

4. Tes endpoint publik:

   ```bash
   curl http://localhost:8080/api/v1/dashboard/summary
   ```

5. Lihat log backend:

   ```bash
   docker compose logs -f app
   ```

6. Hentikan stack (`-v` untuk sekalian hapus volume data Postgres/Redis):

   ```bash
   docker compose down        # data tetap ada
   docker compose down -v     # reset total, skema akan dibuat ulang saat up berikutnya
   ```

Catatan: image build pakai `eclipse-temurin:21-jre-jammy` (bukan varian `-alpine`) untuk
runtime — Ballerina memuat native library `netty-tcnative` yang hanya tersedia untuk glibc,
bukan musl (basis Alpine), jadi Alpine akan gagal start dengan `UnsatisfiedLinkError`.

## Cara 2 — Menjalankan langsung dengan `bal run`

Untuk development harian: build lebih cepat, tidak perlu rebuild image Docker tiap ubah kode.

Prasyarat:
- [Ballerina Swan Lake `2201.13.4`](https://ballerina.io/downloads/) terinstall lokal (versi
  harus sama dengan `distribution` di `Ballerina.toml` agar tidak ada perbedaan compiler).
- PostgreSQL 16 dan Redis 7 berjalan (lokal, atau paling gampang lewat Docker: jalankan
  `docker compose up -d postgres redis` untuk hanya menyalakan dua service pendukung ini
  tanpa build image aplikasi).
- Skema database sudah dibuat di Postgres — jalankan sekali:

  ```bash
  psql -h localhost -U postgres -d swamedia_portal_db -f documentation/database/swamedia_portal_schema_v2.1.sql
  ```

  (atau biarkan `docker compose up -d postgres` yang membuatnya otomatis lewat
  `docker-entrypoint-initdb.d`, lalu koneksikan `bal run` ke Postgres yang di-expose di
  `localhost:5432` itu.)

Langkah menjalankan:

1. Buat `Config.toml` di root project (file ini gitignored, aman berisi secret asli):

   ```toml
   [rayha.swamedia_portal_be.config]
   clientId = "ISI_CLIENT_ID_ASLI"
   clientSecret = "ISI_CLIENT_SECRET_ASLI"
   redirectUri = "http://localhost:5173/"

   iamBaseUrl = "https://iam.apicentrum.biz.id"
   port = 8080

   dbHost = "localhost"
   dbPort = 5432
   dbName = "swamedia_portal_db"
   dbUser = "postgres"
   dbPassword = "ISI_PASSWORD_POSTGRES_LOKAL"
   ```

   Semua nilai configurable lain (path endpoint WSO2 IS, host Redis, CORS origin, dsb) sudah
   punya default yang masuk akal di `modules/config/config.bal` — override di `Config.toml`
   hanya kalau perlu.

2. Jalankan:

   ```bash
   bal run
   ```

3. Backend aktif di `http://localhost:8080` (atau port lain sesuai `port` di `Config.toml`).

### Build & test saja (tanpa menjalankan)

```bash
bal build     # compile + hasilkan target/bin/swamedia_portal_be.jar
bal test      # jalankan seluruh unit test
```

`bal build`/`bal test` **tidak** membutuhkan Postgres/Redis/WSO2 IS menyala — semua koneksi
bersifat lazy (baru benar-benar connect saat endpoint yang butuh koneksi itu benar-benar
dipanggil).

## Smoke Test — Menguji Endpoint

Setelah backend jalan (Docker maupun `bal run`), urutan tercepat memverifikasi semuanya hidup:

1. **Endpoint publik (tanpa token)** — memastikan HTTP listener + koneksi Postgres sehat:

   ```bash
   curl http://localhost:8080/api/v1/dashboard/summary
   ```

   Harusnya `200` dengan `data: { totalProyek, revenueBulanIni, proyekSedangDikerjakan }`.

2. **Login → ambil access token** — butuh kredensial WSO2 IS yang valid (user asli di IS):

   ```bash
   curl -X POST http://localhost:8080/api/v1/auth/login \
     -H "Content-Type: application/json" \
     -d '{"username":"USER_IS","password":"PASSWORD_IS"}'
   ```

   Access token ada di `data.accessToken` pada response. Simpan ke variabel:

   ```bash
   TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/auth/login \
     -H "Content-Type: application/json" \
     -d '{"username":"USER_IS","password":"PASSWORD_IS"}' | jq -r '.data.accessToken')
   ```

3. **Panggil endpoint terproteksi** — sertakan header `Authorization: Bearer <token>`:

   ```bash
   curl http://localhost:8080/api/v1/business/proyek \
     -H "Authorization: Bearer $TOKEN"
   ```

   Tanpa token (atau token invalid/expired) endpoint terproteksi otomatis membalas `401`
   sebelum resource function jalan — itu perilaku yang benar, bukan bug.

> Catatan: `curl`/`jq` di atas hanya contoh — gunakan tool apa pun (Postman, HTTPie, dsb).
> Endpoint yang perlu `created_by`/`updated_by` (POST/PUT/DELETE) mengambilnya dari klaim `sub`
> di access token, jadi header `Authorization` wajib ada.

## Menambah API Baru

Panduan step-by-step (models → repositories → services → main.bal → test), termasuk standar
response API, ada di `documentation/note/README.md`.

## Dokumentasi Tambahan

| Dokumen | Isi |
| --- | --- |
| `documentation/database/swamedia_portal_schema_v2.1.sql` | Skema database terkini (source of truth struktur tabel) |
| `documentation/openapi/swamedia_portal_openapi_v1.1.0.yaml` | Kontrak OpenAPI |
| `documentation/note/Auth-Redis-DB.md` | Pola cache Redis untuk userinfo & role/permission |
| `documentation/note/Frontend-Auth-Middleware.md` | Panduan integrasi auth dari sisi frontend |
| `documentation/note/CHANGELOG_openapi_v1.1.0.md` | Riwayat perubahan kontrak OpenAPI |
