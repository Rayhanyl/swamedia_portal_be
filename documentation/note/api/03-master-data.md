# Modul: Master Data (`/api/v1/master/*`)

Sebelas modul data referensi yang dirujuk modul-modul lain (Proyek, Tagihan, dsb). Semua wajib
mengirim `Authorization: Bearer <accessToken>`.

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.
> Modul Role / Menu / Modul / Role Permission juga berada di bawah `/api/v1/master/`, tetapi
> didokumentasikan terpisah di [04-rbac.md](04-rbac.md).

## Ringkasan Modul

| Modul | Base URL | Modul RBAC | Delete |
| --- | --- | --- | --- |
| [Unit Organisasi](#modul-unit-organisasi) | `/api/v1/master/units` | `UNIT_ORGANISASI` | soft |
| [Industri](#modul-industri) | `/api/v1/master/industries` | `INDUSTRI` | soft |
| [Tags](#modul-tags) | `/api/v1/master/tags` | — (tanpa RBAC) | soft |
| [Resource Tags](#modul-resource-tags) | `/api/v1/master/resource-tags` | `RESOURCE_TAG` | soft |
| [Kategori Surat](#modul-kategori-surat) | `/api/v1/master/kategori-surat` | `KATEGORI_SURAT` | soft |
| [Kategori Finansial Keluar](#modul-kategori-finansial-keluar) | `/api/v1/master/kategori-finansial-keluar` | — (tanpa RBAC) | **fisik** |
| [Jabatan](#modul-jabatan) | `/api/v1/master/jabatan` | — (tanpa RBAC) | — (read-only) |
| [Karyawan](#modul-karyawan) | `/api/v1/master/karyawan` | `KARYAWAN` | soft |
| [Customer](#modul-customer) | `/api/v1/master/customers` | `CUSTOMER` | soft |
| [Contact](#modul-contact) | `/api/v1/master/contacts` | `CONTACT` | soft |
| [Resource Unit](#modul-resource-unit) | `/api/v1/master/resource-unit` | `RESOURCE_UNIT` | soft |

"Modul RBAC" adalah `kodeModul` yang dicek pada matriks permission role (lihat [04-rbac.md](04-rbac.md)).
Bertanda "—" berarti cukup token valid, tanpa cek permission.

## Pola CRUD Bersama

Sepuluh dari sebelas modul mengikuti pola yang persis sama. Dibaca sekali di sini, lalu tiap modul
di bawah hanya mencantumkan yang khas darinya.

| Method | URL | Fungsi | Sukses |
| --- | --- | --- | --- |
| GET | `/{base}` | List berpaginasi + filter | `200` |
| GET | `/{base}/{id}` | Detail satu baris | `200` |
| POST | `/{base}` | Membuat baris baru | `201` |
| PUT | `/{base}/{id}` | Mengubah baris (full replace) | `200` |
| DELETE | `/{base}/{id}` | Menghapus baris | `200` |

Aturan yang berlaku untuk kelimanya:

* **List vs detail berbeda isi.** Endpoint list memuat field inti saja; field audit
  (`createdAt`, `updatedAt`, `createdBy`, `updatedBy`) **hanya ada di response detail**. Jangan
  mengharapkan `createdAt` pada baris hasil list.
* **`page` (default 1) dan `limit` (default 20)** berlaku di semua endpoint list; total ada di
  `meta.pagination`.
* **`search`** mencocokkan sebagian kata (case-insensitive) pada kolom kode/nama modul terkait.
* **PUT = full replace.** Field opsional yang tak dikirim akan **dikosongkan**. Pola aman:
  GET detail → ubah → PUT utuh.
* **POST balas `201`** dengan baris yang baru dibuat (termasuk `id` hasil generate).
* **DELETE balas `200` dengan `data: null`.** Soft delete menyembunyikan baris dari semua endpoint
  (list maupun detail) — setelahnya GET pada id itu menghasilkan `404`.
* **Field audit diisi backend** dari klaim `sub` token. Jangan dikirim di body.

Kode status yang berlaku umum: `400` validasi gagal · `401` token invalid · `403` role tak punya
permission · `404` baris tidak ada/sudah dihapus · `409` kode duplikat atau masih dirujuk baris
lain · `500` kegagalan server. Yang dijelaskan per modul di bawah hanyalah arti spesifiknya.

---

## Modul: Unit Organisasi

Hierarki unit organisasi (induk–anak). Dirujuk hampir semua modul lain lewat `unitId`.

**Base URL:** `/api/v1/master/units` · **Modul RBAC:** `UNIT_ORGANISASI`

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/units` | List unit berpaginasi |
| GET | `/api/v1/master/units/tree` | Seluruh hierarki unit (bersarang, tanpa paginasi) |
| GET | `/api/v1/master/units/{id}` | Detail unit |
| POST | `/api/v1/master/units` | Membuat unit |
| PUT | `/api/v1/master/units/{id}` | Mengubah unit |
| DELETE | `/api/v1/master/units/{id}` | Soft delete unit |

### `GET /api/v1/master/units`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan sebagian pada `kodeUnit`/`namaUnit`. |
| `status` | string | — | `AKTIF` atau `TIDAK_AKTIF`. |
| `parent_id` | int | — | Hanya anak langsung dari unit ini. |
| `page` | int | `1` | Nomor halaman. |
| `limit` | int | `20` | Baris per halaman. |

**Contoh request**

```http
GET /api/v1/master/units?search=digital&status=AKTIF&page=1&limit=20
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar unit berhasil diambil",
  "data": [
    {
      "id": 3,
      "namaUnit": "Digital Business",
      "kodeUnit": "DB",
      "parentUnitId": 1,
      "tipeUnit": "OPERASIONAL",
      "status": "AKTIF"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:01:22.100Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 13, "totalPages": 1 }
  }
}
```

**Penjelasan field**

| Field | Keterangan |
| --- | --- |
| `kodeUnit` | Kode unik unit. **Ikut menyusun `kodeProyek`** saat proyek dibuat, jadi mengubahnya berdampak luas. |
| `parentUnitId` | Unit induk; `null` untuk unit puncak. |
| `tipeUnit` | **Read-only/terhitung:** `STRUKTURAL` bila unit punya anak aktif, `OPERASIONAL` bila daun. Tidak bisa dikirim/diubah — nilainya berubah sendiri saat anak ditambah/dihapus. |
| `status` | `AKTIF` / `TIDAK_AKTIF`. |

### `GET /api/v1/master/units/tree`

Seluruh hierarki unit dalam bentuk bersarang. **Tanpa paginasi dan tanpa parameter** — cocok untuk
tree-select dan diagram struktur organisasi. Untuk tabel dengan filter, pakai endpoint list.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Hierarki unit berhasil diambil",
  "data": [
    {
      "id": 1,
      "namaUnit": "Direktorat Utama",
      "kodeUnit": "DU",
      "parentUnitId": null,
      "tipeUnit": "STRUKTURAL",
      "status": "AKTIF",
      "children": [
        {
          "id": 3,
          "namaUnit": "Digital Business",
          "kodeUnit": "DB",
          "parentUnitId": 1,
          "tipeUnit": "OPERASIONAL",
          "status": "AKTIF",
          "children": []
        }
      ]
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T05:02:40.330Z" }
}
```

`children[]` rekursif dengan bentuk sama; array kosong untuk daun.

### `GET /api/v1/master/units/{id}`

**Path parameter:** `id` (int).

Bentuk `data` sama dengan item list, **ditambah** field audit:

```json
{
  "id": 3,
  "namaUnit": "Digital Business",
  "kodeUnit": "DB",
  "parentUnitId": 1,
  "tipeUnit": "OPERASIONAL",
  "status": "AKTIF",
  "createdAt": "2024-02-01T03:00:00.000Z",
  "updatedAt": "2026-05-12T08:14:00.000Z",
  "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "updatedBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

`createdBy`/`updatedBy` berisi `sub` WSO2 IS (bukan nama). Untuk menampilkan nama, petakan lewat
[Manajemen User](04-rbac.md#modul-manajemen-user).

### `POST /api/v1/master/units`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `namaUnit` | string | ya | Nama unit. |
| `kodeUnit` | string | ya | Kode unik unit. |
| `parentUnitId` | int \| null | tidak | Unit induk; hilangkan/`null` untuk unit puncak. |
| `status` | string | tidak | Default `"AKTIF"`. |

`tipeUnit` tidak diterima — nilainya dihitung backend.

**Contoh request**

```http
POST /api/v1/master/units
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "namaUnit": "Data & AI", "kodeUnit": "DAI", "parentUnitId": 1, "status": "AKTIF" }
```

**Response — 201 Created:** unit yang baru dibuat, `message` = `"Unit berhasil dibuat"`.

### `PUT /api/v1/master/units/{id}`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `namaUnit` | string | ya | Nama baru. |
| `kodeUnit` | string | ya | Kode unik baru. |
| `parentUnitId` | int \| null | tidak | Induk baru; hilangkan/`null` untuk menjadikannya unit puncak. |
| `status` | string | ya | Status baru. |

**Response — 200:** unit setelah diperbarui.

### `DELETE /api/v1/master/units/{id}`

Soft delete (`is_deleted = true`). Response `data: null`.

**Status khas modul ini:** `409` bila unit masih punya anak aktif atau masih dirujuk karyawan/proyek.

---

## Modul: Industri

Sektor industri customer. Master paling sederhana — hanya `kode` dan `nama`.

**Base URL:** `/api/v1/master/industries` · **Modul RBAC:** `INDUSTRI`

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/industries` | List berpaginasi |
| GET | `/api/v1/master/industries/{id}` | Detail |
| POST | `/api/v1/master/industries` | Membuat |
| PUT | `/api/v1/master/industries/{id}` | Mengubah |
| DELETE | `/api/v1/master/industries/{id}` | Soft delete |

### `GET /api/v1/master/industries`

**Query parameter:** `search` (cocokkan `kode`/`nama`), `page` (default `1`), `limit` (default `20`).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar industri berhasil diambil",
  "data": [
    { "id": 4, "kode": "BNK", "nama": "Perbankan" },
    { "id": 5, "kode": "TEL", "nama": "Telekomunikasi" }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:10:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 9, "totalPages": 1 }
  }
}
```

### `POST` / `PUT`

**Body** (sama untuk keduanya; keduanya wajib):

| Field | Tipe | Keterangan |
| --- | --- | --- |
| `kode` | string | Kode unik industri. |
| `nama` | string | Nama industri. |

```json
{ "kode": "MFG", "nama": "Manufaktur" }
```

Detail (`GET /{id}`) menambahkan field audit. `POST` balas `201`, `PUT`/`DELETE` balas `200`.

**Status khas:** `409` `kode` sudah dipakai, atau industri masih dirujuk customer/proyek saat dihapus.

---

## Modul: Tags

Label untuk **Proyek** (dipasang lewat [sub-resource Proyek Tags](05-sales-unit.md#sub-resource-proyek-tags)).

**Base URL:** `/api/v1/master/tags` · **Modul RBAC:** — (cukup token valid; data referensi bersama
tanpa baris `modul` tersendiri)

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/tags` | List berpaginasi |
| GET | `/api/v1/master/tags/{id}` | Detail |
| POST | `/api/v1/master/tags` | Membuat |
| PUT | `/api/v1/master/tags/{id}` | Mengubah |
| DELETE | `/api/v1/master/tags/{id}` | Soft delete |

### `GET /api/v1/master/tags`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan `kode`/`nama`. |
| `unit_id` | int | — | Tag milik unit tertentu. |
| `page` / `limit` | int | `1` / `20` | Paginasi. |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar tag berhasil diambil",
  "data": [
    { "id": 12, "kode": "PRIORITAS", "nama": "Proyek Prioritas", "unitId": null },
    { "id": 13, "kode": "MIGRASI", "nama": "Migrasi Sistem", "unitId": 3 }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:15:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 2, "totalPages": 1 }
  }
}
```

| Field | Keterangan |
| --- | --- |
| `unitId` | Unit pemilik tag. **`null` = tag global** (bisa dipakai semua unit). |
| `kode` | Unik **per unit** — dua unit berbeda boleh memakai kode yang sama. |

### `POST` / `PUT`

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kode` | string | ya | Kode tag. |
| `nama` | string | ya | Nama tag. |
| `unitId` | int \| null | tidak | Unit pemilik; hilangkan/`null` untuk tag global. Pada PUT, menghilangkannya **mengubah tag menjadi global**. |

```json
{ "kode": "MIGRASI", "nama": "Migrasi Sistem", "unitId": 3 }
```

---

## Modul: Resource Tags

Label untuk **Resource Unit**. Sama seperti Tags, ditambah `deskripsi` dan `status`.

**Base URL:** `/api/v1/master/resource-tags` · **Modul RBAC:** `RESOURCE_TAG`

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/resource-tags` | List berpaginasi |
| GET | `/api/v1/master/resource-tags/{id}` | Detail |
| POST | `/api/v1/master/resource-tags` | Membuat |
| PUT | `/api/v1/master/resource-tags/{id}` | Mengubah |
| DELETE | `/api/v1/master/resource-tags/{id}` | Soft delete |

### `GET /api/v1/master/resource-tags`

**Query parameter:** `search`, `unit_id` (int), `status` (`AKTIF`/`TIDAK_AKTIF`), `page`, `limit`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar resource tag berhasil diambil",
  "data": [
    {
      "id": 5,
      "kode": "JAVA",
      "nama": "Java Developer",
      "unitId": 3,
      "deskripsi": "Kompetensi pengembangan Java/Spring",
      "status": "AKTIF"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:20:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 1, "totalPages": 1 }
  }
}
```

### `POST` / `PUT`

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kode` | string | ya | Kode tag. |
| `nama` | string | ya | Nama tag. |
| `unitId` | int \| null | tidak | Unit pemilik; `null` = global. |
| `deskripsi` | string \| null | tidak | Deskripsi bebas. |
| `status` | string | POST: tidak (default `"AKTIF"`) · PUT: **ya** | `AKTIF` / `TIDAK_AKTIF`. |

---

## Modul: Kategori Surat

Master kategori surat (DR-01..DR-09) untuk penomoran di [Daftar Surat](07-e-office.md).

**Base URL:** `/api/v1/master/kategori-surat` · **Modul RBAC:** `KATEGORI_SURAT`

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/kategori-surat` | List berpaginasi |
| GET | `/api/v1/master/kategori-surat/{id}` | Detail |
| POST | `/api/v1/master/kategori-surat` | Membuat |
| PUT | `/api/v1/master/kategori-surat/{id}` | Mengubah |
| DELETE | `/api/v1/master/kategori-surat/{id}` | Soft delete |

### `GET /api/v1/master/kategori-surat`

**Query parameter:** `search` (cocokkan `kode`/`nama`), `status` (`AKTIF`/`TIDAK_AKTIF`), `page`, `limit`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar kategori surat berhasil diambil",
  "data": [
    { "id": 1, "kode": "DR-01", "nama": "Surat Penawaran", "status": "AKTIF", "isDefault": true },
    { "id": 10, "kode": "DR-10", "nama": "Surat Internal Unit", "status": "AKTIF", "isDefault": false }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:25:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 10, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `kode` | Format `DR-XX`. Ikut menyusun nomor surat yang di-generate. |
| `isDefault` | **Read-only.** `true` menandai 9 kategori bawaan hasil seeding — **nonaktifkan tombol Hapus** untuk baris ini di UI. Dikirim di body pun diabaikan; kategori baru selalu `false`. |
| `status` | `TIDAK_AKTIF` berarti tidak bisa dipilih untuk surat **baru**, tetapi surat lama yang sudah memakainya tetap sah. Berbeda dari soft delete. |

### `POST` / `PUT`

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kode` | string | ya | Kode kategori (format `DR-XX`). |
| `nama` | string | ya | Nama kategori. |
| `status` | string | POST: tidak (default `"AKTIF"`) · PUT: **ya** | `AKTIF` / `TIDAK_AKTIF`. |

`isDefault` tidak ada di bentuk request — dikirim pun diabaikan diam-diam.

**Status khas:** `409` `kode` duplikat, atau kategori masih dipakai surat saat dihapus.

---

## Modul: Kategori Finansial Keluar

Master kategori pengeluaran, dirujuk [Pembayaran dan Pengeluaran Perusahaan](06-finansial.md).

**Base URL:** `/api/v1/master/kategori-finansial-keluar` · **Modul RBAC:** — (cukup token valid)

**Perhatian: DELETE di sini bersifat FISIK, bukan soft delete** — tabelnya tidak punya kolom
`is_deleted`. Baris yang masih dirujuk pembayaran/pengeluaran ditolak dengan `409`. Karena tak bisa
dibatalkan, konfirmasikan ke user sebelum memanggilnya.

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/kategori-finansial-keluar` | List berpaginasi |
| GET | `/api/v1/master/kategori-finansial-keluar/{id}` | Detail |
| POST | `/api/v1/master/kategori-finansial-keluar` | Membuat |
| PUT | `/api/v1/master/kategori-finansial-keluar/{id}` | Mengubah |
| DELETE | `/api/v1/master/kategori-finansial-keluar/{id}` | **Hapus fisik** |

### `GET /api/v1/master/kategori-finansial-keluar`

**Query parameter:** `search`, `status` (`AKTIF`/`TIDAK_AKTIF`), `page`, `limit`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar kategori finansial keluar berhasil diambil",
  "data": [
    { "id": 2, "kode": "OPS", "nama": "Operasional", "status": "AKTIF" }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:30:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 6, "totalPages": 1 }
  }
}
```

Detail (`GET /{id}`) menambahkan `createdAt` dan `createdBy` saja — tabel ini **tidak punya**
`updatedAt`/`updatedBy` (update menimpa di tempat tanpa jejak audit).

### `POST` / `PUT`

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kode` | string | ya | Kode unik (1–20 karakter). |
| `nama` | string | ya | Nama kategori (1–100 karakter). |
| `status` | string | POST: tidak (default `"AKTIF"`) · PUT: **ya** | `TIDAK_AKTIF` tidak bisa dipilih untuk entri finansial baru. |

---

## Modul: Jabatan

Master jabatan, sumber dropdown pada form Karyawan. **Read-only** — tidak ada create/update/delete.

**Base URL:** `/api/v1/master/jabatan` · **Modul RBAC:** — (cukup token valid)

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/jabatan` | Daftar jabatan (datar, tanpa paginasi) |

### `GET /api/v1/master/jabatan`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan nama jabatan. |
| `status` | string | **hanya `AKTIF`** | Bila dihilangkan, hanya jabatan `AKTIF` yang dikembalikan. Kirim `TIDAK_AKTIF` secara eksplisit untuk melihat yang nonaktif. |

Perhatikan default-nya: berbeda dari modul lain yang mengembalikan semua status saat filter kosong.
Untuk dropdown, perilaku default inilah yang diinginkan.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar jabatan berhasil diambil",
  "data": [
    {
      "id": 7,
      "namaJabatan": "Account Manager",
      "kategori": "SALES",
      "unitTerkaitId": null,
      "isKombinasiUnit": false,
      "status": "AKTIF"
    },
    {
      "id": 9,
      "namaJabatan": "Assistant Manager",
      "kategori": "STRUKTURAL",
      "unitTerkaitId": 3,
      "isKombinasiUnit": true,
      "status": "AKTIF"
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T05:35:00.000Z" }
}
```

**Penjelasan field**

| Field | Keterangan |
| --- | --- |
| `namaJabatan` | Nama jabatan. |
| `kategori` | Kategori jabatan (mis. `SALES`, `STRUKTURAL`). |
| `unitTerkaitId` | Unit yang terkait jabatan ini; `null` bila berlaku umum. |
| `isKombinasiUnit` | `true` berarti label tampil digabung nama unit (mis. "Assistant Manager Digital Business"). Frontend yang merangkai teks gabungannya. |

Tanpa paginasi — `meta.pagination` tidak ada, `data` berisi seluruh baris.

---

## Modul: Karyawan

Master karyawan — master yang paling banyak dirujuk FK (PIC Sales, PMO, Team Member, Account
Manager, lead Resource Unit).

**Base URL:** `/api/v1/master/karyawan` · **Modul RBAC:** `KARYAWAN`

**Catatan privasi:** `subjectId` (penghubung ke identitas WSO2 IS) **hanya muncul di response detail**,
tidak pernah di list maupun dropdown. Kalau butuh menampilkan tautan akun portal, ambil detailnya.

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/karyawan/dropdown` | Opsi ringan untuk dropdown (tanpa paginasi) |
| GET | `/api/v1/master/karyawan` | List berpaginasi |
| GET | `/api/v1/master/karyawan/{id}` | Detail (termasuk `subjectId`) |
| POST | `/api/v1/master/karyawan` | Membuat |
| PUT | `/api/v1/master/karyawan/{id}` | Mengubah |
| DELETE | `/api/v1/master/karyawan/{id}` | Soft delete |

### `GET /api/v1/master/karyawan/dropdown`

Proyeksi ringan `{id, nama, unitNama}` tanpa paginasi. Pakai ini untuk mengisi combo box (form Team
Member, Resource Unit, Kontrak Payung) — jangan pakai endpoint list yang jauh lebih berat.

**Query parameter:** `unit_id` (int), `status` (string), `search` (string).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Dropdown karyawan berhasil diambil",
  "data": [
    { "id": 42, "nama": "Budi Santoso", "unitNama": "Digital Business" },
    { "id": 43, "nama": "Siti Rahayu", "unitNama": "Data & AI" }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T05:40:00.000Z" }
}
```

### `GET /api/v1/master/karyawan`

**Query parameter:** `search` (cocokkan `nik`/`nama`), `unit_id` (int), `status`
(`AKTIF`/`TIDAK_AKTIF`), `page`, `limit`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar karyawan berhasil diambil",
  "data": [
    {
      "id": 42,
      "nik": "SWA-2019-0042",
      "nama": "Budi Santoso",
      "jabatan": { "id": 7, "namaJabatan": "Account Manager", "kategori": "SALES" },
      "unitId": 3,
      "email": "budi.santoso@swamedia.co.id",
      "noHp": "081234567890",
      "tanggalMasuk": "2019-03-01",
      "status": "AKTIF"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:41:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 87, "totalPages": 5 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `nik` | Nomor induk karyawan, unik. |
| `jabatan` | Objek hasil join (`id`, `namaJabatan`, `kategori`) — **selalu ada**, karena `jabatanId` wajib. Perhatikan: response memberi **objek `jabatan`**, sedangkan request meminta **`jabatanId` (int)**. |
| `unitId` | Id unit saja (tanpa nama). Untuk nama unit, pakai endpoint dropdown atau gabungkan dengan data Unit. |
| `subjectId` | **Tidak ada di list.** Hanya di response detail. |

### `GET /api/v1/master/karyawan/{id}`

Bentuk sama dengan item list, ditambah `subjectId` dan field audit:

```json
{
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
}
```

`subjectId` bernilai `null` bila karyawan belum punya akun portal.

### `POST /api/v1/master/karyawan`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `nik` | string | ya | Nomor induk unik. |
| `nama` | string | ya | Nama karyawan. |
| `jabatanId` | int | ya | FK ke master Jabatan (**int**, bukan objek). |
| `unitId` | int | ya | Unit pemilik. |
| `email` | string | ya | Email karyawan. |
| `noHp` | string \| null | tidak | No HP. |
| `tanggalMasuk` | string \| null | tidak | `YYYY-MM-DD`. |
| `status` | string | tidak | Default `"AKTIF"`. |
| `subjectId` | string \| null | tidak | Id user WSO2 IS yang ditautkan. |

**Contoh request**

```http
POST /api/v1/master/karyawan
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "nik": "SWA-2026-0101",
  "nama": "Andi Wijaya",
  "jabatanId": 7,
  "unitId": 3,
  "email": "andi.wijaya@swamedia.co.id",
  "noHp": "081211112222",
  "tanggalMasuk": "2026-07-01",
  "status": "AKTIF"
}
```

**Response — 201:** karyawan yang baru dibuat (bentuk detail).

### `PUT /api/v1/master/karyawan/{id}`

Field sama dengan POST, tetapi `status` **wajib**. `subjectId` boleh diisi, diganti, atau
dikosongkan — kirim `null` atau string kosong untuk memutus tautan akun portal.

**Ingat semantik full replace:** menghilangkan `noHp` atau `tanggalMasuk` akan **mengosongkan**
kolomnya, bukan mempertahankan nilai lama.

### `DELETE /api/v1/master/karyawan/{id}`

Soft delete. **Status khas:** `409` bila karyawan masih menjadi PIC Sales/PMO proyek aktif atau
masih tercatat sebagai team member.

---

## Modul: Customer

Master customer beserta status peluangnya.

**Base URL:** `/api/v1/master/customers` · **Modul RBAC:** `CUSTOMER`

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/customers` | List berpaginasi |
| GET | `/api/v1/master/customers/{id}` | Detail (termasuk nama AM & industri) |
| POST | `/api/v1/master/customers` | Membuat |
| PUT | `/api/v1/master/customers/{id}` | Mengubah |
| DELETE | `/api/v1/master/customers/{id}` | Soft delete |

### `GET /api/v1/master/customers`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan nama customer. |
| `am_id` | int | — | Filter Account Manager (id karyawan). |
| `industri_id` | int | — | Filter industri. |
| `status_peluang` | string | — | `PROSPEK` / `NEGOSIASI` / `DEAL` / `BATAL`. |
| `jenis_customer` | string | — | `ENTERPRISE` / `BANKING` / `BUMN` / `GOVERNMENT`. |
| `page` / `limit` | int | `1` / `20` | Paginasi. |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar customer berhasil diambil",
  "data": [
    {
      "id": 21,
      "nama": "PT Bank Nusantara",
      "amId": 42,
      "industriId": 4,
      "statusPeluang": "DEAL",
      "jenisCustomer": "BANKING"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:50:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 34, "totalPages": 2 }
  }
}
```

**Penting:** list hanya memuat **id FK mentah** (`amId`, `industriId`) tanpa nama. Untuk kolom nama
di tabel, ambil detail per baris atau gabungkan dengan data master di sisi frontend.

### `GET /api/v1/master/customers/{id}`

Detail **menambahkan nama hasil join** dan field audit:

```json
{
  "id": 21,
  "nama": "PT Bank Nusantara",
  "amId": 42,
  "amNama": "Budi Santoso",
  "industriId": 4,
  "industriNama": "Perbankan",
  "statusPeluang": "DEAL",
  "jenisCustomer": "BANKING",
  "createdAt": "2025-11-02T04:00:00.000Z",
  "updatedAt": null,
  "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "updatedBy": null
}
```

`amNama`/`industriNama` bisa `null` bila FK-nya kosong **atau** baris yang dirujuk sudah di-soft-delete
— tangani keduanya sebagai "—" di UI.

### `POST` / `PUT`

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `nama` | string | ya | Nama customer. |
| `amId` | int \| null | tidak | Account Manager (id karyawan). |
| `industriId` | int \| null | tidak | Industri. |
| `statusPeluang` | string | POST: tidak (default `"PROSPEK"`) · PUT: **ya** | `PROSPEK` / `NEGOSIASI` / `DEAL` / `BATAL`. |
| `jenisCustomer` | string \| null | tidak | `ENTERPRISE` / `BANKING` / `BUMN` / `GOVERNMENT`. |

```json
{
  "nama": "PT Bank Nusantara",
  "amId": 42,
  "industriId": 4,
  "statusPeluang": "NEGOSIASI",
  "jenisCustomer": "BANKING"
}
```

`amNama`/`industriNama` **tidak diterima** di body — keduanya hasil join.

---

## Modul: Contact

Kontak person milik customer.

**Base URL:** `/api/v1/master/contacts` · **Modul RBAC:** `CONTACT`

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/contacts` | List berpaginasi |
| GET | `/api/v1/master/contacts/{id}` | Detail |
| POST | `/api/v1/master/contacts` | Membuat |
| PUT | `/api/v1/master/contacts/{id}` | Mengubah |
| DELETE | `/api/v1/master/contacts/{id}` | Soft delete |

### `GET /api/v1/master/contacts`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `customer_id` | int | — | Kontak milik customer tertentu. Inilah filter utama di layar detail customer. |
| `search` | string | — | Cocokkan nama kontak. |
| `tipe_kontak` | string | — | `UTAMA` / `AKTIF` / `PROSPEK`. |
| `page` / `limit` | int | `1` / `20` | Paginasi. |

**Contoh request**

```http
GET /api/v1/master/contacts?customer_id=21&tipe_kontak=UTAMA
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar kontak berhasil diambil",
  "data": [
    {
      "id": 55,
      "customerId": 21,
      "nama": "Rina Kartika",
      "jabatan": "IT Manager",
      "email": "rina.k@banknusantara.co.id",
      "telepon": "0217654321",
      "tipeKontak": "UTAMA"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T05:55:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 3, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `tipeKontak` | **Peran kontak, bukan status aktif/nonaktif**: `UTAMA` (PIC utama), `AKTIF`, `PROSPEK`. Untuk menyembunyikan kontak, pakai DELETE (soft delete), bukan mengubah field ini. |
| `jabatan` | Jabatan di perusahaan customer — **string bebas**, tidak terkait master Jabatan internal. |

### `POST` / `PUT`

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `customerId` | int | ya | Customer pemilik kontak. |
| `nama` | string | ya | Nama kontak. |
| `jabatan` | string \| null | tidak | Jabatan (teks bebas). |
| `email` | string \| null | tidak | Email. |
| `telepon` | string \| null | tidak | Telepon. |
| `tipeKontak` | string | POST: tidak (default `"AKTIF"`) · PUT: **ya** | `UTAMA` / `AKTIF` / `PROSPEK`. |

---

## Modul: Resource Unit

Informasi kapasitas/headcount per unit. **Satu baris per unit** (unik).

**Base URL:** `/api/v1/master/resource-unit` · **Modul RBAC:** `RESOURCE_UNIT`

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/master/resource-unit` | List berpaginasi |
| GET | `/api/v1/master/resource-unit/{id}` | Detail |
| POST | `/api/v1/master/resource-unit` | Membuat |
| PUT | `/api/v1/master/resource-unit/{id}` | Mengubah |
| DELETE | `/api/v1/master/resource-unit/{id}` | Soft delete |

### `GET /api/v1/master/resource-unit`

**Query parameter:** `search`, `unit_id` (int), `status` (`AKTIF`/`TIDAK_AKTIF`), `page`, `limit`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar resource unit berhasil diambil",
  "data": [
    {
      "id": 8,
      "unitId": 3,
      "unitNama": "Digital Business",
      "leadId": 42,
      "leadNama": "Budi Santoso",
      "jumlah": 24,
      "kapasitasTerpakai": 78.50,
      "status": "AKTIF"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T06:00:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 11, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `unitId` | Unit pemilik — **unik**: satu unit hanya boleh punya satu baris resource. |
| `unitNama`, `leadNama` | Hasil join, read-only. |
| `leadId` / `leadNama` | Karyawan yang memimpin unit; `null` bila belum ditentukan. |
| `jumlah` | Headcount (≥ 0). |
| `kapasitasTerpakai` | Persentase kapasitas terpakai, **0..100** (bukan pecahan 0..1). |

### `POST` / `PUT`

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `unitId` | int | ya | Unit (harus belum punya baris resource). |
| `leadId` | int \| null | tidak | Karyawan lead. |
| `jumlah` | int | tidak | Default `0`, harus ≥ 0. |
| `kapasitasTerpakai` | decimal | tidak | Default `0`, rentang 0..100. |
| `status` | string | POST: tidak (default `"AKTIF"`) · PUT: **ya** | `AKTIF` / `TIDAK_AKTIF`. |

```json
{ "unitId": 3, "leadId": 42, "jumlah": 24, "kapasitasTerpakai": 78.5, "status": "AKTIF" }
```

**Status khas:** `409` bila unit tersebut sudah memiliki baris resource — arahkan user untuk
mengubah baris yang ada, bukan membuat baru.
