# Modul: Sales Unit

Modul inti operasional sales: Proyek (dengan sub-resource Unit Share, Team Member, Proyek Tags),
kontrak (Payung & Biasa), target per unit (Revenue & Sales), serta laporan pencapaian (Revenue Unit
& Sales Matrix).

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.
> Data referensi (Customer, Industri, Unit, Karyawan, Tags) berasal dari
> [Master Data](03-master-data.md).

## Ringkasan Modul

| Modul | Base URL | Modul RBAC |
| --- | --- | --- |
| [Proyek](#modul-proyek) | `/api/v1/business/proyek` | `PROYEK` |
| ├ [Unit Share](#sub-resource-unit-share) | `.../{proyekId}/unit-share` | `PROYEK` |
| ├ [Team Member](#sub-resource-team-member) | `.../{proyekId}/team-member` | `TEAM_MEMBER` |
| └ [Proyek Tags](#sub-resource-proyek-tags) | `.../{proyekId}/tags` | `PROYEK` |
| [Kontrak Payung](#modul-kontrak-payung) | `/api/v1/business/kontrak-payung` | `KONTRAK_PAYUNG` |
| [Kontrak Biasa](#modul-kontrak-biasa) | `/api/v1/business/kontrak-biasa` | — (tanpa RBAC) |
| [Target Revenue Unit](#modul-target-revenue-unit) | `/api/v1/business/target-revenue-unit` | `TARGET_SALES_UNIT` |
| [Revenue Unit](#modul-revenue-unit-laporan) | `/api/v1/business/revenue-unit` | `REVENUE_UNIT` |
| [Target Sales Unit](#modul-target-sales-unit) | `/api/v1/business/target-sales-unit` | `TARGET_SALES_UNIT` |
| [Sales Matrix](#modul-sales-matrix-laporan) | `/api/v1/business/sales-matrix` | `TARGET_SALES_UNIT` |

**Semua nilai uang bertipe `decimal`** (angka JSON, bukan string).

---

# Modul: Proyek

Master proyek beserta seluruh data terkaitnya. Modul yang paling kaya di portal.

**Base URL:** `/api/v1/business/proyek` · **Modul RBAC:** `PROYEK`

## Karakter Khas

* **`kodeProyek` di-generate backend** dari kode unit + tahun. Dikirim di body pun diabaikan.
* **`unitId` dan `tahun` immutable setelah dibuat** — keduanya tertanam di `kodeProyek`, jadi tidak
  bisa diubah lewat PUT.
* **`nilaiBersih` terhitung DB** (`nilaiProyek - subkon`), selalu read-only.
* **`status` memicu log.** Setiap perubahan `status` mencatat baris `log-status`; transisi pertama
  ke `DEAL_KONTRAK` otomatis mengisi `tanggalDeal`.

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/proyek/dropdown` | Opsi ringan (id/kode/nama) untuk dropdown |
| GET | `/api/v1/business/proyek` | List proyek berpaginasi |
| GET | `/api/v1/business/proyek/{id}` | Detail proyek |
| GET | `/api/v1/business/proyek/{id}/log-status` | Riwayat perubahan status |
| POST | `/api/v1/business/proyek` | Membuat proyek |
| PUT | `/api/v1/business/proyek/{id}` | Mengubah proyek |
| DELETE | `/api/v1/business/proyek/{id}` | Soft delete |
| — | `.../{proyekId}/unit-share…` | [Sub-resource Unit Share](#sub-resource-unit-share) |
| — | `.../{proyekId}/team-member…` | [Sub-resource Team Member](#sub-resource-team-member) |
| — | `.../{proyekId}/tags…` | [Sub-resource Proyek Tags](#sub-resource-proyek-tags) |

## `GET /api/v1/business/proyek/dropdown`

Sampai 100 proyek aktif (terbaru dulu), proyeksi ringan `{id, kodeProyek, namaProyek}`. Dipakai form
Tambah Surat. **Query parameter:** `search` (string).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar proyek untuk dropdown",
  "data": [
    { "id": 45, "kodeProyek": "DB-2026-045", "namaProyek": "Migrasi Core Banking" }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T09:00:00.000Z" }
}
```

## `GET /api/v1/business/proyek`

**Query parameter**

| Parameter | Tipe | Keterangan |
| --- | --- | --- |
| `search` | string | Cocokkan `kodeProyek`/`namaProyek`. |
| `customer_id` | int | Filter customer. |
| `industri_id` | int | Filter industri. |
| `unit_id` | int | Filter unit pemilik. |
| `pic_sales_id` | int | Filter PIC Sales (id karyawan). |
| `status` | string | Filter status proyek. |
| `tahun` | int | Filter tahun. |
| `page` / `limit` | int | Paginasi (default `1` / `20`). |

**Contoh response — 200 OK** (dipangkas)

```json
{
  "success": true,
  "message": "Daftar proyek berhasil diambil",
  "data": [
    {
      "id": 45,
      "kodeProyek": "DB-2026-045",
      "customerId": 21,
      "customerNama": "PT Bank Nusantara",
      "industriId": 4,
      "industriNama": "Perbankan",
      "unitId": 3,
      "unitNama": "Digital Business",
      "kontrakPayungId": 7,
      "noKontrakPayung": "KP/2026/007",
      "kontrakBiasaId": null,
      "noKontrakBiasa": null,
      "namaProyek": "Migrasi Core Banking",
      "departemen": "IT",
      "nilaiProyek": 1200000000.00,
      "subkon": 200000000.00,
      "nilaiBersih": 1000000000.00,
      "picSalesId": 42,
      "picSalesNama": "Budi Santoso",
      "pmoId": 43,
      "pmoNama": "Siti Rahayu",
      "noKontrak": "SPK/2026/045",
      "tanggalKontrak": "2026-06-01",
      "tanggalBast": null,
      "tanggalMulai": "2026-06-15",
      "tanggalDeal": "2026-05-20",
      "targetSelesai": "2026-12-31",
      "keteranganPembayaran": "Termin 3x",
      "status": "DEAL_KONTRAK",
      "tahun": 2026
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T09:02:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 45, "totalPages": 3 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `kodeProyek` | **Read-only**, di-generate dari kode unit + tahun. |
| `customerNama` / `industriNama` / `unitNama` / `picSalesNama` / `pmoNama` / `noKontrakPayung` / `noKontrakBiasa` | Hasil join dalam satu query (tanpa N+1), read-only. Nama bisa `null` bila FK kosong/dihapus. |
| `nilaiBersih` | **Terhitung DB** = `nilaiProyek - subkon`. Read-only. |
| `tanggalDeal` | Diisi backend saat pertama kali `status` menjadi `DEAL_KONTRAK`. Tidak diterima dari client. |
| `status` | Siklus proyek (mis. `INFO_PELUANG`, `DEAL_KONTRAK`, dst). Perubahan tercatat di `log-status`. |
| `tahun` | **Immutable** setelah dibuat. |

Field audit hanya di response detail.

## `GET /api/v1/business/proyek/{id}/log-status`

Riwayat transisi status (terbaru dulu). **Read-only** — ditulis backend saat proyek dibuat (status
awal) dan tiap kali `status` berubah.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Riwayat status proyek berhasil diambil",
  "data": [
    {
      "id": 88,
      "proyekId": 45,
      "status": "DEAL_KONTRAK",
      "komentar": "Kontrak ditandatangani",
      "tanggal": "2026-05-20",
      "createdAt": "2026-05-20T04:00:00.000Z",
      "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T09:05:00.000Z" }
}
```

## `POST /api/v1/business/proyek`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `customerId` | int | ya | Customer pemilik. |
| `industriId` | int | ya | Sektor industri. |
| `unitId` | int | ya | Unit pemilik (tertanam di `kodeProyek`). |
| `kontrakPayungId` | int \| null | tidak | Kontrak payung terkait. |
| `kontrakBiasaId` | int \| null | tidak | Kontrak biasa terkait. |
| `namaProyek` | string | ya | Nama proyek. |
| `departemen` | string \| null | tidak | Label departemen. |
| `nilaiProyek` | decimal | ya | Nilai total proyek. |
| `subkon` | decimal | tidak | Porsi subkontraktor (default `0`). |
| `picSalesId` | int | ya | PIC Sales (id karyawan). |
| `pmoId` | int \| null | tidak | PMO (id karyawan). |
| `noKontrak` | string \| null | tidak | Nomor kontrak. |
| `tanggalKontrak` | string \| null | tidak | `YYYY-MM-DD`. |
| `tanggalBast` | string \| null | tidak | `YYYY-MM-DD`. |
| `tanggalMulai` | string \| null | tidak | `YYYY-MM-DD`. |
| `targetSelesai` | string \| null | tidak | `YYYY-MM-DD`. |
| `keteranganPembayaran` | string \| null | tidak | Catatan pembayaran. |
| `status` | string | tidak | Default `"INFO_PELUANG"`. |
| `tahun` | int | tidak | Default tahun berjalan. |

`kodeProyek`/`nilaiBersih`/`tanggalDeal` tidak diterima (server-generated/terhitung).

**Contoh request**

```http
POST /api/v1/business/proyek
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "customerId": 21,
  "industriId": 4,
  "unitId": 3,
  "namaProyek": "Migrasi Core Banking",
  "nilaiProyek": 1200000000.00,
  "subkon": 200000000.00,
  "picSalesId": 42
}
```

**Response — 201:** proyek baru (dengan `kodeProyek` hasil generate).

## `PUT /api/v1/business/proyek/{id}`

**Body** sama dengan POST, kecuali: `unitId`/`tahun` immutable (diabaikan bila dikirim), `subkon`
wajib, dan ada `statusKomentar`:

| Field tambahan | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `status` | string | ya | Status baru. Perubahan dicatat ke `log-status`. |
| `statusKomentar` | string \| null | tidak | Catatan yang dicatat ke `log-status` saat status berubah (diabaikan bila status sama). |

**Response — 200:** proyek setelah diperbarui.

## `DELETE /api/v1/business/proyek/{id}`

Soft delete. Response `data: null`.

## Kode Status — Proyek

| Status | Keterangan |
| --- | --- |
| `200` | List/dropdown/detail/log/update/delete berhasil. |
| `201` | Proyek berhasil dibuat. |
| `400` | Body tidak valid (mis. `nilaiProyek` ≤ 0, `subkon` > `nilaiProyek`, format tanggal salah). |
| `401` | Token tidak valid. |
| `403` | Role pemanggil tidak punya izin `PROYEK`. |
| `404` | Proyek atau FK (`customerId`/`unitId`/`picSalesId`/dll) tidak ditemukan. |
| `409` | Konflik data (mis. kombinasi unik dilanggar). |
| `500` | Kegagalan server/database. |

---

## Sub-resource: Unit Share

Pembagian nilai proyek antar unit. **Modul RBAC-nya `PROYEK`** (mengikuti induk).

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `.../proyek/{proyekId}/unit-share` | Semua share sebuah proyek |
| POST | `.../proyek/{proyekId}/unit-share` | Menambah share |
| PUT | `.../proyek/{proyekId}/unit-share/{id}` | Mengubah share |
| DELETE | `.../proyek/{proyekId}/unit-share/{id}` | Soft delete share |

### `GET .../{proyekId}/unit-share`

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar unit share berhasil diambil",
  "data": [
    {
      "id": 4,
      "proyekId": 45,
      "unitId": 3,
      "unitNama": "Digital Business",
      "nilaiShare": 700000000.00,
      "persentase": 58.33,
      "createdAt": "2026-06-02T02:00:00.000Z",
      "updatedAt": null,
      "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "updatedBy": null
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T09:10:00.000Z" }
}
```

| Field | Keterangan |
| --- | --- |
| `nilaiShare` | Nilai absolut yang dialokasikan ke unit (> 0). |
| `persentase` | Persentase tersimpan (0..100), **informatif** — DB tidak menurunkan satu dari yang lain. Bisa `null`. |

### `POST` / `PUT`

**Path:** `proyekId` (int); PUT juga `id`.

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `unitId` | int | ya | Unit penerima share. |
| `nilaiShare` | decimal | ya | Nilai alokasi (> 0). |
| `persentase` | decimal \| null | tidak | Persentase (0..100). |

**Aturan:** satu pasangan (proyek, unit) unik — menambah unit yang sama dua kali menghasilkan `409`.
Total seluruh share yang tidak dihapus **tidak boleh melebihi `nilaiProyek`**.

**Response:** POST `201`, PUT/DELETE `200`.

### Kode Status — Unit Share

| Status | Keterangan |
| --- | --- |
| `200` / `201` | Berhasil. |
| `400` | `nilaiShare` ≤ 0, atau total share melebihi `nilaiProyek`. |
| `403` | Tidak punya izin `PROYEK`. |
| `404` | Proyek/unit/share tidak ditemukan. |
| `409` | Unit sudah punya share pada proyek ini, atau total melebihi `nilaiProyek`. |

---

## Sub-resource: Team Member

Penugasan karyawan ke proyek per periode. **Modul RBAC-nya `TEAM_MEMBER`** (berbeda dari induk).

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `.../proyek/{proyekId}/team-member` | Semua anggota tim sebuah proyek |
| POST | `.../proyek/{proyekId}/team-member` | Menugaskan anggota |
| PUT | `.../proyek/{proyekId}/team-member/{id}` | Mengubah penugasan |
| DELETE | `.../proyek/{proyekId}/team-member/{id}` | Soft delete penugasan |

### `GET .../{proyekId}/team-member`

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar team member berhasil diambil",
  "data": [
    {
      "id": 11,
      "proyekId": 45,
      "karyawanId": 42,
      "karyawanNama": "Budi Santoso",
      "roleId": 2,
      "roleNama": "Project Manager",
      "tglMulai": "2026-06-15",
      "tglSelesai": null,
      "bobot": 100.00,
      "keterangan": null,
      "undanganStatus": "BELUM_DIKIRIM",
      "undanganSentAt": null,
      "undanganSentBy": null,
      "createdAt": "2026-06-15T02:00:00.000Z",
      "updatedAt": null,
      "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "updatedBy": null
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T09:15:00.000Z" }
}
```

| Field | Keterangan |
| --- | --- |
| `karyawanNama` / `roleNama` | Hasil join, read-only. |
| `roleId` | Peran proyek (`project_role_master`), **bukan** role RBAC. |
| `bobot` | Bobot usaha (0..100), opsional. |
| `undanganStatus` / `undanganSentAt` / `undanganSentBy` | **Dikendalikan backend** (alur email undangan, belum dibangun). Mulai `BELUM_DIKIRIM`; tidak diterima dari payload CRUD. |

### `POST` / `PUT`

**Path:** `proyekId` (int); PUT juga `id`.

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `karyawanId` | int | ya | Karyawan yang ditugaskan. |
| `roleId` | int | ya | Peran proyek. |
| `tglMulai` | string \| null | tidak | `YYYY-MM-DD`. |
| `tglSelesai` | string \| null | tidak | `YYYY-MM-DD`. |
| `bobot` | decimal \| null | tidak | 0..100. |
| `keterangan` | string \| null | tidak | Catatan. |

**Aturan:** karyawan yang sama tak boleh ditugaskan dua kali dengan `tglMulai` sama (unik per
proyek); `tglSelesai` (bila keduanya diisi) tak boleh lebih awal dari `tglMulai`. Field undangan
diabaikan bila dikirim.

**Response:** POST `201`, PUT/DELETE `200`.

### Kode Status — Team Member

| Status | Keterangan |
| --- | --- |
| `200` / `201` | Berhasil. |
| `400` | `tglSelesai` < `tglMulai`, atau `bobot` di luar 0..100. |
| `403` | Tidak punya izin `TEAM_MEMBER`. |
| `404` | Proyek/karyawan/role/penugasan tidak ditemukan. |
| `409` | Karyawan sudah ditugaskan dengan `tglMulai` yang sama. |

---

## Sub-resource: Proyek Tags

Relasi many-to-many proyek ↔ [Tags](03-master-data.md#modul-tags). **Modul RBAC-nya `PROYEK`.**

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `.../proyek/{proyekId}/tags` | Tag yang terpasang di proyek |
| PUT | `.../proyek/{proyekId}/tags` | Mengganti **seluruh** set tag |
| POST | `.../proyek/{proyekId}/tags/{tagId}` | Memasang satu tag (idempoten) |
| DELETE | `.../proyek/{proyekId}/tags/{tagId}` | Melepas satu tag |

Ada dua gaya: **PUT** untuk mengganti seluruh set sekaligus (cocok untuk multi-select yang disimpan
bersama), atau **POST/DELETE per tag** untuk menambah/melepas satu (cocok untuk chip yang
ditambah/dihapus satuan). Ketiganya (GET/PUT/POST/DELETE) mengembalikan daftar tag terkini.

### `GET .../{proyekId}/tags`

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar tag proyek berhasil diambil",
  "data": [
    { "tagsId": 12, "kode": "PRIORITAS", "nama": "Proyek Prioritas", "unitId": null }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T09:20:00.000Z" }
}
```

| Field | Keterangan |
| --- | --- |
| `tagsId` | Id tag. |
| `kode` / `nama` / `unitId` | Hasil join dari master Tags (`unitId` `null` = tag global). |

### `PUT .../{proyekId}/tags`

Mengganti seluruh set tag dalam satu operasi atomik. Id duplikat digabungkan; array kosong `[]`
mengosongkan semua tag. Setiap id harus merujuk tag yang ada (belum dihapus).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `tagIds` | int[] | ya | Set lengkap id tag yang diinginkan. |

```json
{ "tagIds": [12, 13] }
```

**Response — 200:** daftar tag terkini setelah diganti.

### `POST` / `DELETE .../{proyekId}/tags/{tagId}`

**Path:** `proyekId` dan `tagId` (int). Tanpa body. POST idempoten (memasang tag yang sudah ada
tidak error). Keduanya balas `200` dengan daftar tag terkini.

### Kode Status — Proyek Tags

| Status | Keterangan |
| --- | --- |
| `200` | Berhasil (GET/PUT/POST/DELETE). |
| `400` | `tagIds` bukan array of int. |
| `403` | Tidak punya izin `PROYEK`. |
| `404` | Proyek atau salah satu `tagId` tidak ditemukan. |

---

# Modul: Kontrak Payung

Kontrak payung beserta daftar harga per peran (`hargaRole`).

**Base URL:** `/api/v1/business/kontrak-payung` · **Modul RBAC:** `KONTRAK_PAYUNG`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/kontrak-payung/dropdown` | Opsi ringan untuk form Proyek |
| GET | `/api/v1/business/kontrak-payung` | List berpaginasi |
| GET | `/api/v1/business/kontrak-payung/{id}` | Detail (termasuk `hargaRole`) |
| POST | `/api/v1/business/kontrak-payung` | Membuat (dengan `hargaRole` opsional) |
| PUT | `/api/v1/business/kontrak-payung/{id}` | Mengubah |
| DELETE | `/api/v1/business/kontrak-payung/{id}` | Soft delete |

## `GET /api/v1/business/kontrak-payung/dropdown`

Sampai 100 kontrak aktif. **Query parameter:** `customer_id` (int), `search` (string). Proyeksi
`{id, noKontrakPayung, namaKontrak}`.

## `GET /api/v1/business/kontrak-payung`

**Query parameter:** `search`, `customer_id` (int), `page`, `limit`.

List **tidak** memuat `hargaRole` (hanya detail yang memuatnya).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar kontrak payung berhasil diambil",
  "data": [
    {
      "id": 7,
      "customerId": 21,
      "customerNama": "PT Bank Nusantara",
      "noKontrakPayung": "KP/2026/007",
      "namaKontrak": "Payung Layanan TI 2026",
      "tanggalKontrak": "2026-01-15",
      "tanggalMulai": "2026-02-01",
      "tanggalSelesai": "2026-12-31"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T09:30:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 4, "totalPages": 1 }
  }
}
```

## `GET /api/v1/business/kontrak-payung/{id}`

Detail **menambahkan `hargaRole[]`** dan field audit:

```json
{
  "id": 7,
  "customerId": 21,
  "customerNama": "PT Bank Nusantara",
  "noKontrakPayung": "KP/2026/007",
  "namaKontrak": "Payung Layanan TI 2026",
  "tanggalKontrak": "2026-01-15",
  "tanggalMulai": "2026-02-01",
  "tanggalSelesai": "2026-12-31",
  "hargaRole": [
    {
      "id": 1,
      "kontrakPayungId": 7,
      "roleId": 2,
      "roleNama": "Project Manager",
      "tipeHarga": "PER_BULAN",
      "nilai": 25000000.00,
      "keterangan": null
    }
  ],
  "createdAt": "2026-01-16T02:00:00.000Z",
  "updatedAt": null,
  "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "updatedBy": null
}
```

| Field `hargaRole[]` | Keterangan |
| --- | --- |
| `roleId` / `roleNama` | Peran proyek (`project_role_master`); `roleNama` hasil join. |
| `tipeHarga` | `PER_BULAN` atau `PER_PROJECT`. |
| `nilai` | Harga yang disepakati (> 0). |

## `POST /api/v1/business/kontrak-payung`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `customerId` | int | ya | Customer pemilik. |
| `noKontrakPayung` | string | ya | Nomor kontrak unik (maks 50 karakter). |
| `namaKontrak` | string | ya | Nama kontrak (maks 150 karakter). |
| `tanggalKontrak` | string | ya | `YYYY-MM-DD`. |
| `tanggalMulai` | string | ya | `YYYY-MM-DD`. |
| `tanggalSelesai` | string | ya | `YYYY-MM-DD` (tak boleh lebih awal dari `tanggalMulai`). |
| `hargaRole` | array | tidak | Daftar harga per peran (lihat di bawah). |

Setiap elemen `hargaRole[]`: `roleId` (int, wajib), `tipeHarga` (`PER_BULAN`/`PER_PROJECT`, wajib),
`nilai` (decimal > 0, wajib), `keterangan` (string \| null, opsional, maks 255). `id`/`kontrakPayungId`
ditetapkan server.

**Contoh request**

```http
POST /api/v1/business/kontrak-payung
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "customerId": 21,
  "noKontrakPayung": "KP/2026/007",
  "namaKontrak": "Payung Layanan TI 2026",
  "tanggalKontrak": "2026-01-15",
  "tanggalMulai": "2026-02-01",
  "tanggalSelesai": "2026-12-31",
  "hargaRole": [
    { "roleId": 2, "tipeHarga": "PER_BULAN", "nilai": 25000000.00 }
  ]
}
```

**Response — 201:** kontrak baru beserta `hargaRole`.

## `PUT /api/v1/business/kontrak-payung/{id}`

**Body** sama dengan POST. **Semantik `hargaRole`: replace-or-leave** —

* Bila `hargaRole` **ada** di body (termasuk array kosong `[]`), seluruh daftar harga diganti dengan
  isi tersebut.
* Bila `hargaRole` **dihilangkan**, daftar harga lama dibiarkan.

Ini berbeda dari field lain yang mengikuti full replace. Untuk mengosongkan daftar harga, kirim
`"hargaRole": []` eksplisit.

**Response — 200:** kontrak setelah diperbarui.

## `DELETE /api/v1/business/kontrak-payung/{id}`

Soft delete. **Ditolak `409`** selama masih ada proyek/kontrak biasa aktif yang merujuknya.

## Kode Status — Kontrak Payung

| Status | Keterangan |
| --- | --- |
| `200` / `201` | Berhasil. |
| `400` | Body tidak valid (mis. `tanggalSelesai` < `tanggalMulai`, `nilai` harga ≤ 0). |
| `401` | Token tidak valid. |
| `403` | Tidak punya izin `KONTRAK_PAYUNG`. |
| `404` | Kontrak/customer/role tidak ditemukan. |
| `409` | `noKontrakPayung` duplikat, atau kontrak masih dirujuk saat dihapus. |
| `500` | Kegagalan server/database. |

---

# Modul: Kontrak Biasa

Kontrak biasa — bisa berdiri sendiri atau bernaung di bawah kontrak payung (customer sama).

**Base URL:** `/api/v1/business/kontrak-biasa` · **Modul RBAC:** — (cukup token valid; belum ada
baris `modul` untuk kontrak biasa)

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/kontrak-biasa/dropdown` | Opsi ringan untuk form Proyek |
| GET | `/api/v1/business/kontrak-biasa` | List berpaginasi |
| GET | `/api/v1/business/kontrak-biasa/{id}` | Detail |
| POST | `/api/v1/business/kontrak-biasa` | Membuat |
| PUT | `/api/v1/business/kontrak-biasa/{id}` | Mengubah |
| DELETE | `/api/v1/business/kontrak-biasa/{id}` | Soft delete |

## `GET /api/v1/business/kontrak-biasa/dropdown`

**Query parameter:** `customer_id` (int), `search` (string). Proyeksi `{id, noKontrakBiasa, namaKontrak}`.

## `GET /api/v1/business/kontrak-biasa`

**Query parameter:** `search`, `customer_id` (int), `kontrak_payung_id` (int), `page`, `limit`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar kontrak biasa berhasil diambil",
  "data": [
    {
      "id": 15,
      "kontrakPayungId": 7,
      "noKontrakPayung": "KP/2026/007",
      "customerId": 21,
      "customerNama": "PT Bank Nusantara",
      "noKontrakBiasa": "KB/2026/015",
      "namaKontrak": "Implementasi Modul Kartu",
      "tanggalKontrak": "2026-03-01",
      "nilai": 350000000.00
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T09:40:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 8, "totalPages": 1 }
  }
}
```

| Field | Keterangan |
| --- | --- |
| `kontrakPayungId` / `noKontrakPayung` | Kontrak payung induk; **`null` bila berdiri sendiri**. `noKontrakPayung` hasil join. |
| `customerNama` | Hasil join, read-only. |
| `nilai` | Nilai kontrak, **opsional** (`null` bila belum tercatat). |

## `POST` / `PUT`

**Body** (sama untuk keduanya):

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kontrakPayungId` | int \| null | tidak | Kontrak payung induk; bila diisi, harus milik `customerId` yang sama. |
| `customerId` | int | ya | Customer pemilik. |
| `noKontrakBiasa` | string | ya | Nomor kontrak unik (maks 50 karakter). |
| `namaKontrak` | string | ya | Nama kontrak (maks 150 karakter). |
| `tanggalKontrak` | string | ya | `YYYY-MM-DD`. |
| `nilai` | decimal \| null | tidak | Nilai kontrak (> 0 bila diisi). Pada PUT, menghilangkannya **mengosongkan** kolom (full replace). |

**Contoh request**

```http
POST /api/v1/business/kontrak-biasa
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "kontrakPayungId": 7,
  "customerId": 21,
  "noKontrakBiasa": "KB/2026/015",
  "namaKontrak": "Implementasi Modul Kartu",
  "tanggalKontrak": "2026-03-01",
  "nilai": 350000000.00
}
```

**Response:** POST `201`, PUT/DELETE `200`. DELETE soft delete, **ditolak `409`** bila masih dirujuk
proyek aktif.

## Kode Status — Kontrak Biasa

| Status | Keterangan |
| --- | --- |
| `200` / `201` | Berhasil. |
| `400` | Body tidak valid, atau `kontrakPayungId` berbeda customer dari `customerId`. |
| `401` | Token tidak valid. |
| `403` | (Modul ini tidak dijaga RBAC — `403` hanya dari token yang di-denylist.) |
| `404` | Kontrak/customer/kontrak payung tidak ditemukan. |
| `409` | `noKontrakBiasa` duplikat, atau kontrak masih dirujuk saat dihapus. |
| `500` | Kegagalan server/database. |

---

# Modul: Target Revenue Unit

Target revenue per unit per tahun, dipecah ke empat triwulan. **DELETE fisik** (tabel tanpa
`is_deleted`).

**Base URL:** `/api/v1/business/target-revenue-unit` · **Modul RBAC:** `TARGET_SALES_UNIT`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/target-revenue-unit` | List berpaginasi |
| GET | `/api/v1/business/target-revenue-unit/{id}` | Detail |
| POST | `/api/v1/business/target-revenue-unit` | Membuat |
| PUT | `/api/v1/business/target-revenue-unit/{id}` | Mengubah |
| DELETE | `/api/v1/business/target-revenue-unit/{id}` | **Hapus fisik** |

## `GET /api/v1/business/target-revenue-unit`

**Query parameter:** `search`, `unit_id` (int), `tahun` (int), `page`, `limit`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar target revenue unit berhasil diambil",
  "data": [
    {
      "id": 3,
      "unitId": 3,
      "unitNama": "Digital Business",
      "tahun": 2026,
      "targetTw1": 500000000.00,
      "targetTw2": 500000000.00,
      "targetTw3": 750000000.00,
      "targetTw4": 750000000.00,
      "targetTotal": 2500000000.00
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T09:50:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 11, "totalPages": 1 }
  }
}
```

| Field | Keterangan |
| --- | --- |
| `unitNama` | Hasil join, read-only. |
| `targetTw1..4` | Target per triwulan. |
| `targetTotal` | **Terhitung** = jumlah keempat triwulan. Read-only. |

## `POST` / `PUT`

**Body** (sama untuk keduanya):

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `unitId` | int | ya | Unit target. |
| `tahun` | int | ya | Tahun target. |
| `targetTw1` | decimal | tidak | Default `0`, non-negatif. |
| `targetTw2` | decimal | tidak | Default `0`, non-negatif. |
| `targetTw3` | decimal | tidak | Default `0`, non-negatif. |
| `targetTw4` | decimal | tidak | Default `0`, non-negatif. |

**Aturan:** pasangan (unit, tahun) unik.

**Response:** POST `201`, PUT `200`. DELETE `200` (hapus fisik).

## Kode Status — Target Revenue Unit

| Status | Keterangan |
| --- | --- |
| `200` / `201` | Berhasil. |
| `400` | Target negatif atau body tidak valid. |
| `401` | Token tidak valid. |
| `403` | Tidak punya izin `TARGET_SALES_UNIT`. |
| `404` | Target/unit tidak ditemukan. |
| `409` | Pasangan (unit, tahun) sudah ada. |
| `500` | Kegagalan server/database. |

---

# Modul: Revenue Unit (Laporan)

Laporan **read-only** target vs realisasi revenue per unit untuk satu tahun. Realisasi berbasis kas
(dari pencairan `PARSIAL`/`FINAL`, dikelompokkan per unit proyek dan triwulan pencairan).

**Base URL:** `/api/v1/business/revenue-unit` · **Modul RBAC:** `REVENUE_UNIT`
(endpoint `/tw` memakai modul `REVENUE_UNIT_TW`)

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/revenue-unit/chart` | Empat titik triwulan (target vs realisasi) |
| GET | `/api/v1/business/revenue-unit/tw` | Laporan satu triwulan per unit |
| GET | `/api/v1/business/revenue-unit` | Laporan lengkap per unit (semua triwulan + total) |

Semua endpoint: `tahun` opsional (default tahun berjalan), `unit_id` opsional (scope satu unit).

## `GET /api/v1/business/revenue-unit`

**Query parameter:** `tahun` (int), `unit_id` (int).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Revenue unit berhasil diambil",
  "data": [
    {
      "unitId": 3,
      "unitNama": "Digital Business",
      "tahun": 2026,
      "targetTw1": 500000000.00,
      "targetTw2": 500000000.00,
      "targetTw3": 750000000.00,
      "targetTw4": 750000000.00,
      "targetTotal": 2500000000.00,
      "realisasiTw1": 200000000.00,
      "realisasiTw2": 0.00,
      "realisasiTw3": 0.00,
      "realisasiTw4": 0.00,
      "realisasiTotal": 200000000.00,
      "pencapaianPersen": 8.00
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T10:00:00.000Z" }
}
```

| Field | Keterangan |
| --- | --- |
| `target*` | Dari Target Revenue Unit. |
| `realisasi*` | Realisasi kas terhitung dari pencairan. Read-only. |
| `pencapaianPersen` | `realisasiTotal / targetTotal * 100` (`0` bila target `0`). |

## `GET /api/v1/business/revenue-unit/tw`

Laporan satu triwulan. **`triwulan` (1..4) wajib.**

**Query parameter:** `triwulan` (int, **wajib**), `tahun` (int), `unit_id` (int).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Revenue unit per triwulan berhasil diambil",
  "data": [
    {
      "unitId": 3,
      "unitNama": "Digital Business",
      "tahun": 2026,
      "triwulan": 1,
      "target": 500000000.00,
      "realisasi": 200000000.00,
      "pencapaianPersen": 40.00
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T10:02:00.000Z" }
}
```

## `GET /api/v1/business/revenue-unit/chart`

Empat titik triwulan (TW1..TW4) untuk grafik, satu unit atau agregat semua unit.

**Query parameter:** `tahun` (int), `unit_id` (int).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Chart revenue unit berhasil diambil",
  "data": {
    "tahun": 2026,
    "unitId": 3,
    "unitNama": "Digital Business",
    "points": [
      { "triwulan": 1, "label": "TW1", "target": 500000000.00, "realisasi": 200000000.00 },
      { "triwulan": 2, "label": "TW2", "target": 500000000.00, "realisasi": 0.00 },
      { "triwulan": 3, "label": "TW3", "target": 750000000.00, "realisasi": 0.00 },
      { "triwulan": 4, "label": "TW4", "target": 750000000.00, "realisasi": 0.00 }
    ]
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T10:04:00.000Z" }
}
```

`unitId`/`unitNama` `null` bila diagregasi lintas semua unit (`unit_id` tidak dikirim). Selalu 4 titik.

## Kode Status — Revenue Unit

| Status | Keterangan |
| --- | --- |
| `200` | Laporan/chart berhasil. |
| `400` | `triwulan` di luar 1..4 (endpoint `/tw`), atau `tahun` tidak valid. |
| `401` | Token tidak valid. |
| `403` | Tidak punya izin `REVENUE_UNIT` (atau `REVENUE_UNIT_TW` untuk `/tw`). |
| `500` | Kegagalan server/database. |

---

# Modul: Target Sales Unit

Kembaran [Target Revenue Unit](#modul-target-revenue-unit) — target **sales (deal)** per unit per
tahun, dipecah empat triwulan. Bentuk request/response, aturan (pasangan unit+tahun unik, target
non-negatif, `targetTotal` terhitung), dan **DELETE fisik** persis sama.

**Base URL:** `/api/v1/business/target-sales-unit` · **Modul RBAC:** `TARGET_SALES_UNIT`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/target-sales-unit` | List berpaginasi |
| GET | `/api/v1/business/target-sales-unit/{id}` | Detail |
| POST | `/api/v1/business/target-sales-unit` | Membuat |
| PUT | `/api/v1/business/target-sales-unit/{id}` | Mengubah |
| DELETE | `/api/v1/business/target-sales-unit/{id}` | **Hapus fisik** |

**Query parameter list:** `search`, `unit_id` (int), `tahun` (int), `page`, `limit`.

**Body POST/PUT:** `unitId` (int, wajib), `tahun` (int, wajib), `targetTw1..4` (decimal, opsional,
default `0`, non-negatif).

**Contoh response — 200 OK** (bentuk identik Target Revenue Unit, beda konteks: target deal)

```json
{
  "success": true,
  "message": "Daftar target sales unit berhasil diambil",
  "data": [
    {
      "id": 5,
      "unitId": 3,
      "unitNama": "Digital Business",
      "tahun": 2026,
      "targetTw1": 1000000000.00,
      "targetTw2": 1000000000.00,
      "targetTw3": 1500000000.00,
      "targetTw4": 1500000000.00,
      "targetTotal": 5000000000.00
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T10:10:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 11, "totalPages": 1 }
  }
}
```

**Kode status** sama dengan [Target Revenue Unit](#kode-status--target-revenue-unit) (izin modul
`TARGET_SALES_UNIT`).

---

# Modul: Sales Matrix (Laporan)

Laporan **read-only** target vs realisasi **sales (deal)** per unit. Kembaran
[Revenue Unit](#modul-revenue-unit-laporan), tetapi realisasi berbasis deal (`nilaiBersih` proyek
berstatus `DEAL_KONTRAK`, dikelompokkan per unit dan triwulan deal).

**Base URL:** `/api/v1/business/sales-matrix` · **Modul RBAC:** `TARGET_SALES_UNIT`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/sales-matrix/chart` | Empat titik triwulan (target vs realisasi) |
| GET | `/api/v1/business/sales-matrix/tw` | Laporan satu triwulan per unit |
| GET | `/api/v1/business/sales-matrix` | Laporan lengkap per unit |

Parameter dan bentuk response **identik dengan Revenue Unit** (`tahun` opsional default tahun
berjalan, `unit_id` opsional; `/tw` wajib `triwulan` 1..4). Berikut contoh laporan lengkap:

**Contoh response — 200 OK** (`GET /api/v1/business/sales-matrix`)

```json
{
  "success": true,
  "message": "Sales matrix berhasil diambil",
  "data": [
    {
      "unitId": 3,
      "unitNama": "Digital Business",
      "tahun": 2026,
      "targetTw1": 1000000000.00,
      "targetTw2": 1000000000.00,
      "targetTw3": 1500000000.00,
      "targetTw4": 1500000000.00,
      "targetTotal": 5000000000.00,
      "realisasiTw1": 1000000000.00,
      "realisasiTw2": 0.00,
      "realisasiTw3": 0.00,
      "realisasiTw4": 0.00,
      "realisasiTotal": 1000000000.00,
      "pencapaianPersen": 20.00
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T10:20:00.000Z" }
}
```

Endpoint `/tw` mengembalikan array `{unitId, unitNama, tahun, triwulan, target, realisasi,
pencapaianPersen}`, dan `/chart` mengembalikan `{tahun, unitId, unitNama, points[]}` dengan empat
titik `{triwulan, label, target, realisasi}` — sama persis dengan Revenue Unit.

## Kode Status — Sales Matrix

| Status | Keterangan |
| --- | --- |
| `200` | Laporan/chart berhasil. |
| `400` | `triwulan` di luar 1..4 (`/tw`), atau `tahun` tidak valid. |
| `401` | Token tidak valid. |
| `403` | Tidak punya izin `TARGET_SALES_UNIT`. |
| `500` | Kegagalan server/database. |
