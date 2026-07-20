# Modul: e-Office — Daftar Surat

Penomoran surat otomatis. Modul ini men-generate `nomor` surat berdasarkan kategori dan tahun, jadi
frontend **tidak pernah** menyusun/mengirim nomor sendiri.

**Base URL:** `/api/v1/business/daftar-surat` · **Modul RBAC:** `DAFTAR_SURAT`

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.

## Karakter Khas Modul Ini

* **`nomor`, `tahun`, dan `urutan` di-generate backend.** Dikirim di body pun diabaikan diam-diam.
* **Sebagian field immutable setelah dibuat.** `kategoriSuratId`, `tahun`, `urutan`, dan `nomor`
  tidak bisa diubah lewat PUT — hanya `tanggal`, `proyekId`, `tujuan`, `perihal`, `keterangan`.
* **DELETE = pembatalan, bukan hapus fisik.** Memerlukan body berisi alasan (untuk jejak audit),
  dan surat tetap tersimpan (dengan flag `isDibatalkan`).

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/daftar-surat` | List surat berpaginasi |
| GET | `/api/v1/business/daftar-surat/preview-nomor` | Pratinjau nomor berikutnya (tanpa memesan) |
| GET | `/api/v1/business/daftar-surat/{id}` | Detail satu surat |
| POST | `/api/v1/business/daftar-surat` | Membuat surat (nomor otomatis) |
| PUT | `/api/v1/business/daftar-surat/{id}` | Mengubah field yang boleh diubah |
| DELETE | `/api/v1/business/daftar-surat/{id}` | Membatalkan surat (butuh alasan) |

## `GET /api/v1/business/daftar-surat`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan sebagian pada `nomor`/`tujuan`/`perihal`. |
| `tahun` | int | **tahun berjalan** | Bila dihilangkan, hanya surat tahun ini yang tampil. |
| `kategori_surat_id` | int | — | Filter kategori surat. |
| `proyek_id` | int | — | Filter surat milik proyek tertentu. |
| `include_dibatalkan` | boolean | `false` | `true` ikut menampilkan surat yang sudah dibatalkan (untuk layar audit/laporan). |
| `page` | int | `1` | Nomor halaman. |
| `limit` | int | `20` | Baris per halaman. |

Perhatikan default `tahun` = tahun berjalan — berbeda dari modul lain. Untuk arsip lintas tahun,
kirim `tahun` secara eksplisit.

**Contoh request**

```http
GET /api/v1/business/daftar-surat?tahun=2026&kategori_surat_id=1&page=1&limit=20
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar surat berhasil diambil",
  "data": [
    {
      "id": 120,
      "kategoriSuratId": 1,
      "kategoriKode": "DR-01",
      "kategoriNama": "Surat Penawaran",
      "proyekId": 45,
      "kodeProyek": "DB-2026-045",
      "namaProyek": "Migrasi Core Banking",
      "tanggal": "2026-07-10",
      "tahun": 2026,
      "urutan": 37,
      "nomor": "037/DR-01/SWA/VII/2026",
      "tujuan": "PT Bank Nusantara",
      "perihal": "Penawaran Jasa Implementasi",
      "keterangan": null,
      "alasanPembatalan": null,
      "isDibatalkan": false
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T07:00:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 37, "totalPages": 2 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `nomor` | Nomor surat hasil generate. **Read-only.** |
| `kategoriKode` / `kategoriNama` | Hasil join dari master Kategori Surat. |
| `proyekId` / `kodeProyek` / `namaProyek` | Proyek terkait (opsional). `kodeProyek`/`namaProyek` `null` bila `proyekId` kosong **atau** proyeknya sudah di-soft-delete. |
| `urutan` | Nomor urut dalam kombinasi (kategori, tahun). Read-only. |
| `alasanPembatalan` | `null` untuk surat aktif; terisi bila sudah dibatalkan. |
| `isDibatalkan` | `false` untuk surat aktif. Selalu ada di response (list & detail). |

Field audit (`createdAt`/`updatedAt`/`createdBy`/`updatedBy`) hanya ada di response detail.

## `GET /api/v1/business/daftar-surat/preview-nomor`

Menampilkan nomor yang **akan** diperoleh untuk kombinasi (kategori, tanggal) tertentu — untuk
mengisi preview di form Tambah Surat. **Tidak memesan apa pun**: nilainya bisa berubah bila ada
surat lain yang tersimpan lebih dulu. Jadikan indikatif, jangan disimpan.

**Query parameter**

| Parameter | Tipe | Keterangan |
| --- | --- | --- |
| `kategori_surat_id` | int | Kategori yang dipilih di form. |
| `tanggal` | string | Tanggal surat (`YYYY-MM-DD`) — bulan/tahunnya ikut menyusun nomor. |

**Contoh request**

```http
GET /api/v1/business/daftar-surat/preview-nomor?kategori_surat_id=1&tanggal=2026-07-10
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Preview nomor surat",
  "data": { "nomorPreview": "038/DR-01/SWA/VII/2026" },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T07:02:00.000Z" }
}
```

## `GET /api/v1/business/daftar-surat/{id}`

**Path parameter:** `id` (int). Bentuk `data` sama dengan item list, **ditambah** field audit
(`createdAt`, `updatedAt`, `createdBy`, `updatedBy`).

## `POST /api/v1/business/daftar-surat`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `kategoriSuratId` | int | ya | Kategori surat (menentukan prefiks nomor). |
| `proyekId` | int \| null | tidak | Proyek terkait. |
| `tanggal` | string | ya | Tanggal surat (`YYYY-MM-DD`). |
| `tujuan` | string | ya | Tujuan/penerima surat. |
| `perihal` | string | ya | Perihal/subjek. |
| `keterangan` | string \| null | tidak | Catatan tambahan. |

`nomor`/`tahun`/`urutan` **tidak** ada di body — dikirim pun diabaikan.

**Contoh request**

```http
POST /api/v1/business/daftar-surat
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "kategoriSuratId": 1,
  "proyekId": 45,
  "tanggal": "2026-07-10",
  "tujuan": "PT Bank Nusantara",
  "perihal": "Penawaran Jasa Implementasi"
}
```

**Response — 201 Created:** surat yang baru dibuat (dengan `nomor` hasil generate), `message` =
`"Surat berhasil ditambahkan"`.

## `PUT /api/v1/business/daftar-surat/{id}`

Hanya mengubah field yang boleh diubah. `kategoriSuratId`/`tahun`/`urutan`/`nomor` **immutable** —
dikirim pun diabaikan.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `tanggal` | string | ya | Tanggal baru (`YYYY-MM-DD`). |
| `proyekId` | int \| null | tidak | Proyek terkait baru; hilangkan/`null` untuk melepas kaitan. |
| `tujuan` | string | ya | Tujuan baru. |
| `perihal` | string | ya | Perihal baru. |
| `keterangan` | string \| null | tidak | Catatan baru; hilangkan untuk mengosongkan. |

**Response — 200:** surat setelah diperbarui.

## `DELETE /api/v1/business/daftar-surat/{id}`

**Pembatalan surat, bukan hapus fisik** — surat ditandai `isDibatalkan: true` dan tetap ada.
**Memerlukan body** berisi alasan (minimal 5 karakter, tidak boleh kosong) untuk jejak audit.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `alasanPembatalan` | string | ya | Alasan pembatalan (≥ 5 karakter). |

**Contoh request**

```http
DELETE /api/v1/business/daftar-surat/120
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "alasanPembatalan": "Penawaran dibatalkan atas permintaan customer" }
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Surat berhasil dibatalkan",
  "data": {
    "id": 120,
    "nomor": "037/DR-01/SWA/VII/2026",
    "alasanPembatalan": "Penawaran dibatalkan atas permintaan customer"
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T07:10:00.000Z" }
}
```

Response-nya **proyeksi ringkas** (bukan objek surat lengkap) — hanya `id`, `nomor`, dan alasan.
Tidak ada penomoran ulang otomatis: bila perlu surat pengganti, buat baru lewat POST biasa (yang
akan mendapat nomor urut berikutnya).

## Kode Status — Daftar Surat

| Status | Keterangan |
| --- | --- |
| `200` | List/preview/detail/update/cancel berhasil. |
| `201` | Surat berhasil dibuat. |
| `400` | Body tidak valid: field wajib kosong, format `tanggal` salah, atau `alasanPembatalan` < 5 karakter saat membatalkan. |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `DAFTAR_SURAT` untuk aksi ini. |
| `404` | Surat dengan `id` tersebut tidak ada, atau `kategoriSuratId`/`proyekId` yang dirujuk tidak ditemukan. |
| `409` | Surat sudah dibatalkan sebelumnya (membatalkan dua kali). |
| `500` | Kegagalan server/database. |
