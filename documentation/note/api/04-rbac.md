# Modul: RBAC (Role, Menu & Manajemen User)

Enam modul yang mengatur **siapa boleh melakukan apa** di portal. Kelimanya adalah layar
administrator, dan konsumen utamanya adalah halaman "Role & Permission", "Menu", dan "Manajemen
User".

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.

**Lima dari enam modul di sini dijaga modul RBAC `ROLE_PERMISSION` yang sama** (Role, Menu, Modul,
Role Permission, Role Menu) — satu izin membuka kelimanya. Manajemen User dijaga modul `USER` yang
terpisah, jadi sebuah role bisa saja boleh mengelola user tanpa boleh mengubah matriks permission.

## Bagaimana Ketiga Bagian Ini Bertemu

Ketiga tabel di bawah ini saling terkait tapi **disimpan dan disimpan-ulang secara terpisah**:

```
User (WSO2 IS)  --swaportal_role_id-->  Role  --+--> Role Permission (per Modul: C/R/U/D/approve/export + scope)
                                                |
                                                +--> Role Menu (menu mana yang tampil di navigasi)
```

* **Role Permission** menentukan **apa yang boleh dilakukan** — ini yang benar-benar ditegakkan
  backend pada setiap request.
* **Role Menu** menentukan **apa yang terlihat** di navigasi. Ini murni tampilan.

Keduanya independen: mencentang menu **tidak** memberi izin apa pun, dan mencabut menu **tidak**
memblokir API-nya. Selalu atur keduanya bersamaan agar user tidak melihat menu yang berujung `403`,
atau sebaliknya kehilangan menu untuk fitur yang sebenarnya boleh ia akses.

## Efek Penyimpanan ke Sesi User

Menyimpan Role Permission atau Role Menu **membatalkan cache Redis** (`role:{id}:permissions` /
`role:{id}:menu`) yang dibaca middleware auth. Artinya perubahan berlaku pada request berikutnya
**tanpa perlu user login ulang**.

Konsekuensi untuk frontend: user yang sedang aktif bisa tiba-tiba mendapat `403` di layar yang tadi
terbuka, atau menu berubah setelah refresh. Setelah admin menyimpan, sarankan user terdampak
memuat ulang [Menu Saya](02-dashboard-dan-self-service.md#modul-menu-saya).

---

# Modul: Role

Master role portal. Nilai `id`-nya dipakai atribut `swaportal_role_id` di WSO2 IS untuk mengikat
user ke sebuah role.

**Base URL:** `/api/v1/master/roles` · **Modul RBAC:** `ROLE_PERMISSION`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/roles` | List role berpaginasi |
| GET | `/api/v1/master/roles/{id}` | Detail role |
| POST | `/api/v1/master/roles` | Membuat role |
| PUT | `/api/v1/master/roles/{id}` | Mengubah role |
| DELETE | `/api/v1/master/roles/{id}` | **Hapus fisik** role |

Modul ini mengikuti [pola CRUD bersama](03-master-data.md#pola-crud-bersama) (paginasi, field audit
hanya di detail, PUT = full replace), **kecuali** DELETE-nya hapus fisik — lihat di bawah.

## `GET /api/v1/master/roles`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan sebagian pada `kodeRole`/`namaRole`. |
| `status` | string | — | `AKTIF` atau `TIDAK_AKTIF`. |
| `page` | int | `1` | Nomor halaman. |
| `limit` | int | `20` | Baris per halaman. |

**Contoh request**

```http
GET /api/v1/master/roles?status=AKTIF&page=1&limit=20
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar role berhasil diambil",
  "data": [
    {
      "id": 2,
      "kodeRole": "ADMIN_UNIT",
      "namaRole": "Administrator Unit",
      "deskripsi": "Mengelola data operasional pada unitnya sendiri",
      "status": "AKTIF"
    },
    {
      "id": 3,
      "kodeRole": "VIEWER",
      "namaRole": "Viewer",
      "deskripsi": null,
      "status": "AKTIF"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T06:10:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 5, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `id` | **Nilai yang dipakai `swaportal_role_id`** di WSO2 IS, dan yang menjadi `{roleId}` pada endpoint Role Permission/Role Menu. |
| `kodeRole` | Kode unik role. |
| `deskripsi` | Bisa `null`. |
| `status` | `AKTIF` / `TIDAK_AKTIF`. |

## `GET /api/v1/master/roles/{id}`

**Path parameter:** `id` (int).

Bentuk `data` sama dengan item list, **ditambah** field audit:

```json
{
  "id": 2,
  "kodeRole": "ADMIN_UNIT",
  "namaRole": "Administrator Unit",
  "deskripsi": "Mengelola data operasional pada unitnya sendiri",
  "status": "AKTIF",
  "createdAt": "2024-01-10T02:00:00.000Z",
  "updatedAt": "2026-03-02T09:20:00.000Z",
  "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "updatedBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

## `POST /api/v1/master/roles`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kodeRole` | string | ya | Kode unik role. |
| `namaRole` | string | ya | Nama role. |
| `deskripsi` | string \| null | tidak | Deskripsi bebas. |
| `status` | string | tidak | Default `"AKTIF"`. |

**Contoh request**

```http
POST /api/v1/master/roles
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "kodeRole": "FINANCE_STAFF",
  "namaRole": "Staff Keuangan",
  "deskripsi": "Mengelola tagihan dan pembayaran",
  "status": "AKTIF"
}
```

**Response — 201 Created:** role yang baru dibuat, `message` = `"Role berhasil dibuat"`.

Role baru lahir **tanpa permission dan tanpa menu sama sekali**. Setelah POST berhasil, arahkan
admin ke layar Role Permission dan Role Menu — kalau tidak, user dengan role ini akan bisa login
tapi tak melihat/melakukan apa pun.

## `PUT /api/v1/master/roles/{id}`

**Body** — sama dengan POST, tetapi `status` **wajib**:

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kodeRole` | string | ya | Kode unik baru. |
| `namaRole` | string | ya | Nama baru. |
| `deskripsi` | string \| null | tidak | Menghilangkannya akan **mengosongkan** deskripsi (full replace). |
| `status` | string | ya | Status baru. |

**Response — 200:** role setelah diperbarui.

Mengubah `status` menjadi `TIDAK_AKTIF` **tidak** otomatis memblokir user yang memakainya —
penegakan izin tetap mengacu ke matriks permission. Untuk benar-benar menutup akses, cabut
permission-nya atau nonaktifkan akun user lewat
[Manajemen User](#put-apiv1manajemen-usersubjectidstatus).

## `DELETE /api/v1/master/roles/{id}`

**Hapus fisik, bukan soft delete** — tabel `role` tidak punya kolom `is_deleted`. Baris
`role_permission` dan `role_menu` milik role tersebut ikut dibersihkan. Tidak bisa dibatalkan:
konfirmasikan ke user lebih dulu.

Endpoint ini **tidak menerima body**. Response `data: null`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Role berhasil dihapus",
  "data": null,
  "errors": null,
  "meta": { "timestamp": "2026-07-17T06:12:00.000Z" }
}
```

## Kode Status — Role

| Status | Keterangan |
| --- | --- |
| `200` | List/detail/update/delete berhasil. |
| `201` | Role berhasil dibuat. |
| `400` | Body tidak valid (mis. `kodeRole`/`namaRole` kosong, `status` di luar `AKTIF`/`TIDAK_AKTIF`). |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `ROLE_PERMISSION` untuk aksi ini. |
| `404` | Role dengan `id` tersebut tidak ada. |
| `409` | `kodeRole` sudah dipakai role lain, atau role masih dipakai user saat dihapus. |
| `500` | Kegagalan server/database. |

---

# Modul: Menu

Master menu navigasi (pohon induk–anak). Modul ini **hanya mendefinisikan struktur menu**; soal
menu mana yang tampil untuk role tertentu diatur di [Role Menu](#modul-role-menu).

**Base URL:** `/api/v1/master/menu` · **Modul RBAC:** `ROLE_PERMISSION`

Tabel `menu` **tidak punya kolom audit maupun `is_deleted`**: tidak ada `createdAt`/`createdBy` di
response mana pun, dan create/update/delete bersifat langsung (hapus fisik). Karena itu tidak ada
perbedaan isi antara response list dan detail.

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/menu/tree` | Seluruh hierarki menu (bersarang, tanpa paginasi) |
| GET | `/api/v1/master/menu` | List menu datar, berpaginasi |
| GET | `/api/v1/master/menu/{id}` | Detail satu menu |
| POST | `/api/v1/master/menu` | Membuat node menu |
| PUT | `/api/v1/master/menu/{id}` | Mengubah node menu |
| DELETE | `/api/v1/master/menu/{id}` | **Hapus fisik** node menu |

## `GET /api/v1/master/menu/tree`

Seluruh menu dalam bentuk bersarang. **Tanpa paginasi dan tanpa parameter.** Cocok untuk pratinjau
struktur navigasi dan tree-select.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Hierarki menu berhasil diambil",
  "data": [
    {
      "id": 1,
      "parentId": null,
      "kodeMenu": "MASTER",
      "namaMenu": "Master Data",
      "path": null,
      "icon": "database",
      "urutan": 1,
      "status": "AKTIF",
      "children": [
        {
          "id": 4,
          "parentId": 1,
          "kodeMenu": "MASTER_KARYAWAN",
          "namaMenu": "Karyawan",
          "path": "/master/karyawan",
          "icon": "users",
          "urutan": 1,
          "status": "AKTIF",
          "children": []
        }
      ]
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T06:15:00.000Z" }
}
```

`children[]` rekursif dengan bentuk yang sama; array kosong untuk daun.

## `GET /api/v1/master/menu`

List datar berpaginasi — untuk tabel pengelolaan menu.

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan sebagian pada `kodeMenu`/`namaMenu`. |
| `status` | string | — | `AKTIF` atau `TIDAK_AKTIF`. |
| `parent_id` | int | — | Hanya anak langsung dari menu ini. |
| `page` | int | `1` | Nomor halaman. |
| `limit` | int | `20` | Baris per halaman. |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar menu berhasil diambil",
  "data": [
    {
      "id": 4,
      "parentId": 1,
      "kodeMenu": "MASTER_KARYAWAN",
      "namaMenu": "Karyawan",
      "path": "/master/karyawan",
      "icon": "users",
      "urutan": 1,
      "status": "AKTIF"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T06:16:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 28, "totalPages": 2 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `parentId` | Menu induk; `null` untuk node puncak. |
| `kodeMenu` | Kode unik menu. |
| `path` | Route frontend (mis. `/master/karyawan`). **`null` berarti node grup murni** — hanya wadah, tidak bisa diklik. |
| `icon` | Identifier ikon; frontend yang memetakannya ke ikon nyata. Bisa `null`. |
| `urutan` | Urutan tampil di antara sesama anak dari induk yang sama. Tree sudah terurut dari backend. |
| `status` | `TIDAK_AKTIF` menyembunyikan menu dari navigasi tanpa menghapusnya. |

## `GET /api/v1/master/menu/{id}`

**Path parameter:** `id` (int). Mengembalikan satu objek menu — **bentuknya identik dengan item
list** (tanpa `children`, tanpa field audit).

## `POST /api/v1/master/menu`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `parentId` | int \| null | tidak | Menu induk; hilangkan/`null` untuk node puncak. |
| `kodeMenu` | string | ya | Kode unik menu. |
| `namaMenu` | string | ya | Label menu. |
| `path` | string \| null | tidak | Route frontend; kosongkan untuk node grup. |
| `icon` | string \| null | tidak | Identifier ikon. |
| `urutan` | int | tidak | Default `0`. |
| `status` | string | tidak | Default `"AKTIF"`. |

**Contoh request**

```http
POST /api/v1/master/menu
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "parentId": 1,
  "kodeMenu": "MASTER_CUSTOMER",
  "namaMenu": "Customer",
  "path": "/master/customer",
  "icon": "briefcase",
  "urutan": 2,
  "status": "AKTIF"
}
```

**Response — 201 Created:** node menu yang baru dibuat.

Menu baru **belum tampil untuk role mana pun** sampai ditugaskan lewat
[Role Menu](#put-apiv1masterrole-menusroleid).

## `PUT /api/v1/master/menu/{id}`

**Body** — sama dengan POST, tetapi `urutan` dan `status` **wajib**. Berlaku semantik full replace:
menghilangkan `path`/`icon`/`parentId` akan **mengosongkan** kolomnya.

**Response — 200:** node menu setelah diperbarui.

## `DELETE /api/v1/master/menu/{id}`

**Hapus fisik.** Ditolak `409` selama menu masih punya sub-menu aktif — hapus anaknya dulu, atau
pindahkan ke induk lain. Tidak menerima body; response `data: null`.

## Kode Status — Menu

| Status | Keterangan |
| --- | --- |
| `200` | List/tree/detail/update/delete berhasil. |
| `201` | Menu berhasil dibuat. |
| `400` | Body tidak valid (mis. `kodeMenu`/`namaMenu` kosong). |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `ROLE_PERMISSION` untuk aksi ini. |
| `404` | Menu dengan `id` tersebut tidak ada. |
| `409` | `kodeMenu` duplikat, atau menu masih punya sub-menu aktif saat dihapus. |
| `500` | Kegagalan server/database. |

---

# Modul: Modul

Daftar tetap modul aplikasi hasil seeding — inilah **baris-baris pada matriks Role Permission**.
**Read-only**: tidak ada create/update/delete. Panggil endpoint ini untuk merender baris grid
permission, jangan menuliskan daftar modul secara hardcode di frontend.

**Base URL:** `/api/v1/master/modul` · **Modul RBAC:** `ROLE_PERMISSION`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/modul` | Daftar modul (datar, terurut `urutan`, tanpa paginasi) |

## `GET /api/v1/master/modul`

**Tidak ada parameter** — tidak ada filter, tidak ada paginasi.

**Contoh request**

```http
GET /api/v1/master/modul
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar modul berhasil diambil",
  "data": [
    { "id": 1, "kodeModul": "UNIT_ORGANISASI", "namaModul": "Unit Organisasi", "urutan": 1 },
    { "id": 2, "kodeModul": "KARYAWAN", "namaModul": "Karyawan", "urutan": 2 },
    { "id": 8, "kodeModul": "PEMBAYARAN", "namaModul": "Pembayaran", "urutan": 8 }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T06:20:00.000Z" }
}
```

**Penjelasan field**

| Field | Keterangan |
| --- | --- |
| `id` | Nilai yang dikirim sebagai `modulId` saat menyimpan matriks permission. |
| `kodeModul` | Kode modul yang ditegakkan backend (mis. `KARYAWAN`) — sama dengan kolom "Modul RBAC" pada dokumentasi tiap modul. |
| `namaModul` | Label tampil di grid Role & Permission. |
| `urutan` | Urutan tampil. Data sudah terurut dari backend. |

Tanpa paginasi — `meta.pagination` tidak ada, `data` berisi seluruh baris.

## Kode Status — Modul

| Status | Keterangan |
| --- | --- |
| `200` | Daftar berhasil diambil. |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin baca `ROLE_PERMISSION`. |
| `500` | Kegagalan server/database. |

---

# Modul: Role Permission

Matriks izin per role — **inilah yang benar-benar ditegakkan backend** pada setiap request.
Disimpan sebagai satu kesatuan: layar "Role & Permission" mengirim seluruh grid sekaligus, bukan
per sel.

**Base URL:** `/api/v1/master/role-permissions` · **Modul RBAC:** `ROLE_PERMISSION`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/role-permissions/{roleId}` | Matriks permission lengkap milik satu role |
| PUT | `/api/v1/master/role-permissions/{roleId}` | Mengganti seluruh matriks permission role |

Tidak ada POST/DELETE — matriks selalu ada untuk setiap role (lihat di bawah).

## `GET /api/v1/master/role-permissions/{roleId}`

**Path parameter:** `roleId` (int) — `id` dari [modul Role](#modul-role).

Mengembalikan **satu baris untuk setiap modul yang ada**, termasuk modul yang belum pernah diatur
untuk role ini. Untuk modul yang belum diatur, semua flag `can*` bernilai `false` dan `scope`
bernilai `"ALL"`. Jadi frontend bisa langsung merender grid dari response ini tanpa perlu
menggabungkannya dengan `GET /api/v1/master/modul`.

**Contoh request**

```http
GET /api/v1/master/role-permissions/2
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Matriks permission role berhasil diambil",
  "data": {
    "roleId": 2,
    "kodeRole": "ADMIN_UNIT",
    "namaRole": "Administrator Unit",
    "items": [
      {
        "modulId": 2,
        "kodeModul": "KARYAWAN",
        "namaModul": "Karyawan",
        "canCreate": true,
        "canRead": true,
        "canUpdate": true,
        "canDelete": false,
        "canApprove": false,
        "canExport": true,
        "scope": "UNIT_SENDIRI"
      },
      {
        "modulId": 8,
        "kodeModul": "PEMBAYARAN",
        "namaModul": "Pembayaran",
        "canCreate": false,
        "canRead": false,
        "canUpdate": false,
        "canDelete": false,
        "canApprove": false,
        "canExport": false,
        "scope": "ALL"
      }
    ]
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T06:25:00.000Z" }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `roleId`, `kodeRole`, `namaRole` | Identitas role pemilik matriks — cukup untuk judul layar tanpa memanggil endpoint Role lagi. |
| `items[]` | Satu entri per modul, **selalu lengkap** (termasuk modul yang belum diatur). |
| `modulId` | Id modul; inilah yang dikirim balik saat PUT. |
| `canCreate` / `canRead` / `canUpdate` / `canDelete` | Izin CRUD. Backend memetakan method HTTP ke aksi: `POST`=create, `PUT`/`PATCH`=update, `DELETE`=delete, sisanya (`GET`/`HEAD`)=read. |
| `canApprove` | Hanya bermakna untuk modul yang punya alur approval (**Pembayaran** dan **Pengeluaran Perusahaan**). Ditegakkan saat path memuat segmen `approve`/`reject`. Untuk modul lain, nilainya diabaikan. |
| `canExport` | Izin ekspor (Excel/PDF); ditegakkan saat path memuat segmen `export`. |
| `scope` | `ALL` = seluruh data; `UNIT_SENDIRI` = hanya data unit milik user. |

Perhatikan bahwa `canRead: false` berarti user **tidak bisa membuka layar modul itu sama sekali** —
semua GET-nya dibalas `403`.

## `PUT /api/v1/master/role-permissions/{roleId}`

**Mengganti seluruh matriks sekaligus.** Modul yang tidak disertakan di `items` **kehilangan seluruh
izinnya**. Cara aman: GET matriksnya, ubah di memori, lalu PUT balik apa adanya.

**Path parameter:** `roleId` (int).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `items` | array | ya | Set lengkap izin per modul. |

Setiap elemen `items[]`:

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `modulId` | int | ya | Id modul dari `GET /api/v1/master/modul`. |
| `canCreate` | boolean | ya | Izin membuat. |
| `canRead` | boolean | ya | Izin membaca. |
| `canUpdate` | boolean | ya | Izin mengubah. |
| `canDelete` | boolean | ya | Izin menghapus. |
| `canApprove` | boolean | ya | Izin approve/reject (hanya berlaku di Pembayaran & Pengeluaran Perusahaan). |
| `canExport` | boolean | ya | Izin ekspor. |
| `scope` | string | ya | `ALL` atau `UNIT_SENDIRI`. |

Semua flag **wajib** — kirim `false` secara eksplisit, jangan dihilangkan.

**Contoh request**

```http
PUT /api/v1/master/role-permissions/2
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "items": [
    {
      "modulId": 2,
      "canCreate": true,
      "canRead": true,
      "canUpdate": true,
      "canDelete": false,
      "canApprove": false,
      "canExport": true,
      "scope": "UNIT_SENDIRI"
    },
    {
      "modulId": 8,
      "canCreate": false,
      "canRead": true,
      "canUpdate": false,
      "canDelete": false,
      "canApprove": false,
      "canExport": false,
      "scope": "ALL"
    }
  ]
}
```

**Response — 200 OK:** matriks setelah disimpan, bentuknya **sama persis dengan response GET**
(`roleId` + `kodeRole` + `namaRole` + `items[]` lengkap), `message` = `"Matriks permission role
berhasil disimpan"`. Pakai response ini untuk merender ulang grid — tidak perlu GET lagi.

Setelah PUT berhasil, cache Redis role tersebut dibersihkan dan izin baru berlaku pada request
berikutnya. **Termasuk untuk diri sendiri**: admin yang mencabut izin `ROLE_PERMISSION` miliknya
sendiri akan langsung terkunci dari layar ini.

## Kode Status — Role Permission

| Status | Keterangan |
| --- | --- |
| `200` | Matriks berhasil diambil/disimpan. |
| `400` | Body tidak valid: `items` bukan array, ada flag yang hilang, atau `scope` di luar `ALL`/`UNIT_SENDIRI`. |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `ROLE_PERMISSION` untuk aksi ini. |
| `404` | Role dengan `roleId` tersebut tidak ada, atau ada `modulId` yang tidak dikenal. |
| `500` | Kegagalan server/database. |

---

# Modul: Role Menu

Menentukan **menu mana yang tampil** untuk sebuah role. Murni tampilan — tidak memberi izin apa
pun (lihat [penjelasan di atas](#bagaimana-ketiga-bagian-ini-bertemu)). Sama seperti Role
Permission, disimpan sebagai satu kesatuan.

**Base URL:** `/api/v1/master/role-menus` · **Modul RBAC:** `ROLE_PERMISSION`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/role-menus/{roleId}` | Pohon menu lengkap + tanda `assigned` untuk role tersebut |
| PUT | `/api/v1/master/role-menus/{roleId}` | Mengganti seluruh set menu milik role |

## `GET /api/v1/master/role-menus/{roleId}`

**Path parameter:** `roleId` (int).

Mengembalikan **seluruh pohon menu** (bukan hanya yang ditugaskan), setiap node ditandai
`assigned`. Bentuk ini langsung cocok untuk tree dengan checkbox: render pohonnya, centang yang
`assigned: true`.

**Contoh request**

```http
GET /api/v1/master/role-menus/2
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Menu role berhasil diambil",
  "data": {
    "roleId": 2,
    "kodeRole": "ADMIN_UNIT",
    "namaRole": "Administrator Unit",
    "items": [
      {
        "id": 1,
        "parentId": null,
        "kodeMenu": "MASTER",
        "namaMenu": "Master Data",
        "path": null,
        "icon": "database",
        "urutan": 1,
        "status": "AKTIF",
        "assigned": true,
        "children": [
          {
            "id": 4,
            "parentId": 1,
            "kodeMenu": "MASTER_KARYAWAN",
            "namaMenu": "Karyawan",
            "path": "/master/karyawan",
            "icon": "users",
            "urutan": 1,
            "status": "AKTIF",
            "assigned": true,
            "children": []
          },
          {
            "id": 5,
            "parentId": 1,
            "kodeMenu": "MASTER_CUSTOMER",
            "namaMenu": "Customer",
            "path": "/master/customer",
            "icon": "briefcase",
            "urutan": 2,
            "status": "AKTIF",
            "assigned": false,
            "children": []
          }
        ]
      }
    ]
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T06:30:00.000Z" }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `items[]` | **Seluruh** pohon menu, bukan hanya yang ditugaskan — node tak-ditugaskan tetap muncul dengan `assigned: false`. |
| `assigned` | `true` bila role ini punya menu tersebut. |
| `children[]` | Rekursif, bentuk sama. |

Field lain (`parentId`, `path`, `icon`, `urutan`, `status`) artinya sama dengan
[modul Menu](#modul-menu).

## `PUT /api/v1/master/role-menus/{roleId}`

**Mengganti seluruh set menu role sekaligus.** Id yang tidak disertakan menjadi tidak ditugaskan.

**Path parameter:** `roleId` (int).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `menuIds` | int[] | ya | Set lengkap id menu yang ditugaskan. Array kosong `[]` mencabut semua menu. |

**Contoh request**

```http
PUT /api/v1/master/role-menus/2
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "menuIds": [1, 4, 5] }
```

**Response — 200 OK:** matriks menu setelah disimpan, bentuknya **sama persis dengan response GET**,
`message` = `"Menu role berhasil disimpan"`.

Dua hal yang perlu ditangani frontend saat menyusun `menuIds`:

* **Sertakan induknya.** Menugaskan menu anak tanpa induknya bisa membuat menu itu tak terjangkau di
  navigasi. Saat user mencentang anak, centang otomatis induk-induknya.
* **Selaraskan dengan permission.** Menu yang ditugaskan tapi modulnya `canRead: false` akan tampil
  lalu berujung `403` saat diklik.

## Kode Status — Role Menu

| Status | Keterangan |
| --- | --- |
| `200` | Menu role berhasil diambil/disimpan. |
| `400` | Body tidak valid (`menuIds` bukan array of int). |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `ROLE_PERMISSION` untuk aksi ini. |
| `404` | Role dengan `roleId` tersebut tidak ada, atau ada id menu yang tidak dikenal. |
| `500` | Kegagalan server/database. |

---

# Modul: Manajemen User

Mengelola akun user portal. Berbeda dari modul lain, penulisan di sini **diteruskan ke WSO2 IS lewat
SCIM2**, sementara pembacaan dilayani dari tabel cache lokal (`user_cache`) hasil sinkronisasi.

**Base URL:** `/api/v1/manajemen-user` · **Modul RBAC:** `USER` (bukan `ROLE_PERMISSION`)

**Identitasnya `subjectId`, bukan `id` numerik.** Semua path parameter di modul ini berupa string
subject id WSO2 IS (mis. `a1b2c3d4-e5f6-7890-abcd-ef1234567890`) — nilai yang sama dengan
`karyawan.subjectId` dan dengan `createdBy`/`updatedBy` di modul lain.

**Konsistensi baca-tulis:** karena baca berasal dari cache lokal sedangkan tulis pergi ke WSO2 IS,
data pada list bisa tertinggal dari kondisi sebenarnya sampai job rekonsiliasi berjalan. Endpoint
tulis mengembalikan baris hasil write-through, jadi **pakai response-nya untuk memperbarui tabel di
layar** alih-alih memanggil GET list ulang.

**`user_cache` juga di-sync tiap login berhasil** — bukan hanya lewat endpoint modul ini. Setiap
[`POST /api/v1/auth/login` / `POST /api/v1/auth/token`](01-autentikasi.md#post-apiv1authlogin)
sukses men-mirror klaim `sub`/`name`/`email` dari id_token ke `user_cache` (best-effort, baris yang
sudah identik di-skip). Jadi baris `user_cache` seorang user juga otomatis ter-update begitu dia
login, tidak melulu menunggu admin mengubahnya lewat modul ini atau job rekonsiliasi.

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/manajemen-user` | List user berpaginasi (+ karyawan tertaut) |
| GET | `/api/v1/manajemen-user/{subjectId}` | Detail satu user |
| POST | `/api/v1/manajemen-user` | Membuat user baru di WSO2 IS |
| PUT | `/api/v1/manajemen-user/{subjectId}` | Mengubah profil user (nama, email) |
| PUT | `/api/v1/manajemen-user/{subjectId}/role` | Menetapkan/mencabut role portal |
| PUT | `/api/v1/manajemen-user/{subjectId}/status` | Mengaktifkan/menonaktifkan akun |
| GET | `/api/v1/manajemen-user/{subjectId}/akun` | Identitas WSO2 IS user lain (untuk prefill form edit Super Admin) |
| PUT | `/api/v1/manajemen-user/{subjectId}/akun` | Super Admin mengubah **data** akun user lain (nama, organization, country, email, telepon, role, group) |
| PUT | `/api/v1/manajemen-user/{subjectId}/password` | Super Admin **reset password** user lain (terpisah dari update data) |

Tidak ada DELETE — akun tidak dihapus, melainkan dinonaktifkan lewat endpoint `/status`.

## `GET /api/v1/manajemen-user`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan sebagian pada nama/email. |
| `status` | string | — | Filter status akun hasil sinkronisasi. |
| `page` | int | `1` | Nomor halaman. |
| `limit` | int | `20` | Baris per halaman. |

**Contoh request**

```http
GET /api/v1/manajemen-user?search=budi&page=1&limit=20
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar user berhasil diambil",
  "data": [
    {
      "subjectId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "nama": "Budi Santoso",
      "email": "budi.santoso@swamedia.co.id",
      "status": "ACTIVE",
      "syncSource": "WSO2_IS",
      "lastSyncedAt": "2026-07-17T02:00:00.000Z",
      "karyawanId": 42,
      "karyawanNama": "Budi Santoso"
    },
    {
      "subjectId": "b2c3d4e5-f6a7-8901-bcde-f23456789012",
      "nama": "Rina Kartika",
      "email": "rina.kartika@swamedia.co.id",
      "status": "ACTIVE",
      "syncSource": "WSO2_IS",
      "lastSyncedAt": "2026-07-17T02:00:00.000Z",
      "karyawanId": null,
      "karyawanNama": null
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T06:40:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 64, "totalPages": 4 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `subjectId` | Id user WSO2 IS — **kunci utama**, dipakai di semua path parameter modul ini. |
| `nama`, `email`, `status` | Nilai hasil cache dari WSO2 IS. **Bisa `null`** bila baris belum pernah tersinkronisasi. |
| `syncSource` | Sumber sinkronisasi, umumnya `"WSO2_IS"`. |
| `lastSyncedAt` | Waktu sinkronisasi terakhir; `null` bila belum pernah. Berguna untuk memberi tahu user seberapa mutakhir datanya. |
| `karyawanId` / `karyawanNama` | Karyawan yang tertaut ke akun ini; **`null` bila akun belum terhubung ke karyawan mana pun** — tampilkan sebagai "belum tertaut". Tautannya dibuat dari sisi [Karyawan](03-master-data.md#modul-karyawan) (`subjectId`), bukan dari modul ini. |

Perhatikan: **`roleId` tidak ada di response ini.** Role tersimpan sebagai atribut
`swaportal_role_id` di WSO2 IS, tidak ikut di-cache. Endpoint `/role` menuliskannya, tapi nilai saat
ini tidak terbaca lewat modul ini.

## `GET /api/v1/manajemen-user/{subjectId}`

**Path parameter:** `subjectId` (string).

Mengembalikan satu user, **bentuknya identik dengan item list** (tidak ada field tambahan — tabel
cache tak punya kolom audit).

## `POST /api/v1/manajemen-user`

Membuat user baru di WSO2 IS lewat SCIM2, lalu menuliskannya ke cache lokal.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `userName` | string | ya | Username login, unik di WSO2 IS. |
| `email` | string | ya | Email user. |
| `nama` | string | ya | Nama tampil. |
| `password` | string | ya | Password awal. |
| `roleId` | int \| null | tidak | Role portal ([id dari modul Role](#modul-role)); ditulis ke atribut `swaportal_role_id`. |

**`swaportal_group_id` otomatis diisi `swamedia_portal_app`** (`config:appGroupId`) untuk setiap user
baru — bukan field yang dikirim di body. Wajib ada supaya user bisa login sama sekali: gerbang
keanggotaan aplikasi di `services:buildLoginResponse` menolak login siapa pun yang klaim
`swaportal_group_id`-nya tidak cocok.

**Contoh request**

```http
POST /api/v1/manajemen-user
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "userName": "andi.wijaya",
  "email": "andi.wijaya@swamedia.co.id",
  "nama": "Andi Wijaya",
  "password": "K@taSandiAwal123",
  "roleId": 2
}
```

**Contoh response — 201 Created**

```json
{
  "success": true,
  "message": "User berhasil dibuat",
  "data": {
    "subjectId": "c3d4e5f6-a7b8-9012-cdef-345678901234",
    "nama": "Andi Wijaya",
    "email": "andi.wijaya@swamedia.co.id",
    "status": "ACTIVE",
    "syncSource": "WSO2_IS",
    "lastSyncedAt": "2026-07-17T06:45:00.000Z",
    "karyawanId": null,
    "karyawanNama": null
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T06:45:00.000Z" }
}
```

`password` **tidak pernah** muncul di response mana pun. Ambil `subjectId` dari response ini bila
ingin langsung menautkannya ke karyawan.

Tanpa `roleId`, user bisa login tapi tak punya izin apa pun. Bila dikosongkan saat create, tetapkan
kemudian lewat endpoint `/role`.

## `PUT /api/v1/manajemen-user/{subjectId}`

Mengubah profil user (nama & email) lewat SCIM2. **Tidak bisa** mengubah username, password, role,
atau status — masing-masing punya jalurnya sendiri.

**Path parameter:** `subjectId` (string).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `email` | string | ya | Email baru. |
| `nama` | string | ya | Nama tampil baru. |

**Contoh request**

```http
PUT /api/v1/manajemen-user/c3d4e5f6-a7b8-9012-cdef-345678901234
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "email": "andi.w@swamedia.co.id", "nama": "Andi Wijaya" }
```

**Response — 200:** baris user setelah diperbarui, `message` = `"User berhasil diperbarui"`.

Mengubah email di sini **tidak** mengubah email pada baris [Karyawan](03-master-data.md#modul-karyawan)
yang tertaut — keduanya kolom terpisah dan harus diperbarui sendiri-sendiri. `email` di sini adalah
**identitas login WSO2 IS** (yang diubah admin lewat SCIM2); `karyawan.email` yang diubah user sendiri
lewat [`PUT /api/v1/profil-saya`](02-dashboard-dan-self-service.md#put-apiv1profil-saya) adalah kontak
HR lokal. Keduanya tidak pernah disinkronkan otomatis oleh backend ini.

## `PUT /api/v1/manajemen-user/{subjectId}/role`

Menetapkan atau mencabut role portal (atribut `swaportal_role_id`).

**Path parameter:** `subjectId` (string).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `roleId` | int \| null | **ya** (boleh bernilai `null`) | Id role portal; kirim `null` untuk **mencabut** role. |

Field ini wajib ada, tapi `null` adalah nilai yang sah — berbeda dari menghilangkannya.

**Contoh request**

```http
PUT /api/v1/manajemen-user/c3d4e5f6-a7b8-9012-cdef-345678901234/role
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "roleId": 3 }
```

Mencabut role:

```json
{ "roleId": null }
```

**Response — 200:** baris user, `message` = `"Role user berhasil diperbarui"`. Perhatikan response
**tidak memuat `roleId`** (lihat catatan di endpoint list) — anggap sukses `200` sebagai
konfirmasinya.

User yang rolenya dicabut kehilangan seluruh izin, tetapi akunnya tetap bisa login. Untuk benar-benar
menutup akses, nonaktifkan akunnya.

## `PUT /api/v1/manajemen-user/{subjectId}/status`

Mengaktifkan/menonaktifkan akun (atribut SCIM `active`). Inilah pengganti DELETE di modul ini.

**Path parameter:** `subjectId` (string).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `active` | boolean | ya | `true` mengaktifkan, `false` menonaktifkan akun. |

**Contoh request**

```http
PUT /api/v1/manajemen-user/c3d4e5f6-a7b8-9012-cdef-345678901234/status
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "active": false }
```

**Response — 200:** baris user setelah diperbarui, `message` = `"Status user berhasil diperbarui"`.

Menonaktifkan akun mencegah login **berikutnya**, tetapi access token yang sudah beredar tetap sah
sampai kedaluwarsa. Untuk memutus sesi seketika, cabut tokennya lewat
[`POST /api/v1/auth/revoke`](01-autentikasi.md).

## `GET /api/v1/manajemen-user/{subjectId}/akun`

Mengambil identitas WSO2 IS milik user **target** saat ini — dipanggil sebelum menampilkan form edit
Super Admin, supaya field-nya terisi nilai terkini alih-alih kosong.

**Path parameter:** `subjectId` (string).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Akun user berhasil diambil",
  "data": {
    "subjectId": "c3d4e5f6-a7b8-9012-cdef-345678901234",
    "email": "andi.wijaya@swamedia.co.id",
    "firstName": "Andi",
    "lastName": "Wijaya",
    "telepon": null,
    "organization": "PT Swamedia Informatika",
    "country": "Indonesia",
    "roleId": 2,
    "roleName": "Administrator Unit",
    "groupId": "swamedia_portal_app"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-18T04:15:00.000Z" }
}
```

Bentuk `data` **identik** dengan response `PUT .../akun` di bawah.

**Status:** `200` berhasil · `401` token tidak valid/kedaluwarsa · `403` role pemanggil tidak punya
izin `USER` · `404` `subjectId` tidak ditemukan di cache lokal, atau tidak ditemukan di WSO2 IS ·
`500` kegagalan server (termasuk WSO2 IS tidak dapat dihubungi).

## `PUT /api/v1/manajemen-user/{subjectId}/akun`

Versi "sekali jalan" untuk Super Admin: mengubah nama depan/belakang, organization, country, email,
telepon, role, dan group portal user lain **dalam satu request** (murni wewenang admin). Ini pasangan
admin dari [Akun Saya](02-dashboard-dan-self-service.md#modul-akun-saya) — bentuk body dan
semantiknya identik, ditambah `roleId` dan `groupId`. **Password tidak di sini** — reset password
lewat [`PUT .../password`](#put-apiv1manajemen-usersubjectidpassword) yang terpisah.

Endpoint ini berjalan dengan **akun Super Admin WSO2 IS** (Basic Auth) — sama seperti seluruh endpoint
tulis SCIM2 lain di modul ini (lihat catatan auth di [README.md](../../../README.md#pengaturan-self-service)
soal kenapa bukan token app-level).

**Path parameter:** `subjectId` (string) — user **target**, bukan pemanggil.

**Body** — semua field opsional; hanya field yang dikirim yang diubah. Minimal harus ada satu field.

| Field | Tipe | Keterangan |
| --- | --- | --- |
| `email` | string | Email login baru. |
| `firstName` | string | Nama depan baru. Tidak boleh string kosong bila dikirim. |
| `lastName` | string | Nama belakang baru. Tidak boleh string kosong bila dikirim. |
| `telepon` | string | Nomor mobile baru. Maks 20 karakter. Kirim `""` untuk mengosongkan. |
| `organization` | string | Nama organisasi. |
| `country` | string | Negara. |
| `roleId` | int | Role portal baru untuk user ini. |
| `groupId` | string | Group portal (mis. `"swamedia_portal_app"`). |

**Catatan `roleId`:** field ini hanya bisa **mengganti** role (mengirim sebuah id). Untuk
**mencabut/mengosongkan** role user, tetap gunakan
[`PUT /api/v1/manajemen-user/{subjectId}/role`](#put-apiv1manajemen-usersubjectidrole) dengan
`{"roleId": null}` — endpoint `/akun` ini tidak mendukung null-clear untuk role.

**Contoh request** (ganti data profil + role)

```http
PUT /api/v1/manajemen-user/c3d4e5f6-a7b8-9012-cdef-345678901234/akun
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "firstName": "Andi", "lastName": "Wijaya", "organization": "PT Swamedia Informatika", "roleId": 3 }
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Akun user berhasil diperbarui",
  "data": {
    "subjectId": "c3d4e5f6-a7b8-9012-cdef-345678901234",
    "email": "andi.wijaya@swamedia.co.id",
    "firstName": "Andi",
    "lastName": "Wijaya",
    "telepon": null,
    "organization": "PT Swamedia Informatika",
    "country": "Indonesia",
    "roleId": 3,
    "roleName": "Manager",
    "groupId": "swamedia_portal_app"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-18T04:20:00.000Z" }
}
```

Bentuk response **identik** dengan [Akun Saya](02-dashboard-dan-self-service.md#put-apiv1akun-saya) —
nilai **terkini** hasil baca dari WSO2 IS setelah update, bukan echo dari request.

**Status:** `200` berhasil · `400` tidak ada field terkirim, format email salah,
`firstName`/`lastName` kosong, atau `roleId` tidak dikenal · `401` token tidak
valid/kedaluwarsa · `403` role pemanggil tidak punya izin `USER` · `404` `subjectId` tidak ditemukan
di cache lokal · `500` kegagalan server/database, **atau WSO2 IS tidak dapat dihubungi** (anggap
perubahan kemungkinan besar tidak tersimpan).

## `PUT /api/v1/manajemen-user/{subjectId}/password`

Super Admin **reset password** user lain di WSO2 IS — operasi terpisah dari update data `.../akun`
(sesuai form FE yang memisahkan ganti password dari edit data). Tanpa perlu password lama (murni
wewenang admin). Berjalan dengan **akun Super Admin WSO2 IS** (Basic Auth), sama seperti `.../akun`.

**Path parameter:** `subjectId` (string) — user **target**, bukan pemanggil.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `password` | string | ya | Password baru. Minimal 6 karakter. |

**Contoh request**

```http
PUT /api/v1/manajemen-user/c3d4e5f6-a7b8-9012-cdef-345678901234/password
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "password": "PasswordDireset123!" }
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Password user berhasil diperbarui",
  "data": null,
  "errors": null,
  "meta": { "timestamp": "2026-07-18T04:22:00.000Z" }
}
```

**Status:** `200` berhasil · `400` password < 6 karakter · `401` token tidak valid/kedaluwarsa ·
`403` role pemanggil tidak punya izin `USER` · `404` `subjectId` tidak ditemukan di cache lokal ·
`500` kegagalan server, **atau WSO2 IS tidak dapat dihubungi** (anggap perubahan kemungkinan besar
tidak tersimpan).

## Kode Status — Manajemen User

| Status | Keterangan |
| --- | --- |
| `200` | List/detail/update berhasil. |
| `201` | User berhasil dibuat di WSO2 IS. |
| `400` | Body tidak valid (mis. `userName`/`email`/`password` kosong, password tak memenuhi kebijakan WSO2 IS, `active` bukan boolean). |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `USER` untuk aksi ini. |
| `404` | `subjectId` tidak ditemukan, atau `roleId` yang dikirim tidak dikenal. |
| `409` | `userName`/`email` sudah dipakai user lain di WSO2 IS. |
| `500` | Kegagalan server/database, **atau WSO2 IS tidak dapat dihubungi**. Untuk endpoint tulis, artinya perubahan kemungkinan besar tidak tersimpan — minta user mencoba lagi, jangan tampilkan sebagai sukses. |
