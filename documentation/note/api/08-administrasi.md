# Modul: Administrasi (Audit Log & Konfigurasi Sistem)

Dua modul administrator: jejak audit (read-only) dan registry konfigurasi global.

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.

---

# Modul: Audit Log

Laporan atas tabel `audit_log` yang bersifat **append-only** — baris ditulis internal oleh proses
lain (mis. saat surat dibatalkan), bukan lewat API ini. **Read-only**: tidak ada
create/update/delete.

**Base URL:** `/api/v1/audit-log` · **Modul RBAC:** `AUDIT_TRAIL`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/audit-log` | List entri audit berpaginasi + filter |
| GET | `/api/v1/audit-log/{id}` | Detail satu entri |

## `GET /api/v1/audit-log`

**Query parameter**

| Parameter | Tipe | Keterangan |
| --- | --- | --- |
| `table_name` | string | Filter tabel yang diaudit (mis. `nomor_surat`). |
| `aksi` | string | `CREATE` / `UPDATE` / `DELETE`. |
| `aktor` | string | `sub` pelaku perubahan. |
| `record_id` | string | Id baris yang diaudit (disimpan sebagai teks). |
| `date_from` | string | Batas bawah tanggal (`YYYY-MM-DD`). |
| `date_to` | string | Batas atas tanggal (`YYYY-MM-DD`). |
| `page` | int | Nomor halaman (default `1`). |
| `limit` | int | Baris per halaman (default `20`). |

**Contoh request**

```http
GET /api/v1/audit-log?table_name=nomor_surat&aksi=DELETE&date_from=2026-07-01&date_to=2026-07-31
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar audit log berhasil diambil",
  "data": [
    {
      "id": 501,
      "tableName": "nomor_surat",
      "recordId": "120",
      "aksi": "DELETE",
      "aktor": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "ipAddress": null,
      "perubahan": {
        "is_dibatalkan": { "old": false, "new": true },
        "alasan_pembatalan": { "old": null, "new": "Dibatalkan atas permintaan customer" }
      },
      "waktu": "2026-07-17T07:10:00.000Z"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T07:20:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 1, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `tableName` | Nama tabel yang diaudit. |
| `recordId` | Id baris yang berubah — **string**, karena kunci sebagian tabel bukan angka. |
| `aksi` | `CREATE` / `UPDATE` / `DELETE`. |
| `aktor` | `sub` WSO2 IS pelaku. Untuk nama, petakan lewat [Manajemen User](04-rbac.md#modul-manajemen-user). |
| `ipAddress` | Alamat IP pemanggil. **Saat ini selalu `null`** (belum diisi di mana pun). |
| `perubahan` | Detail perubahan berbentuk objek `{ "kolom": { "old": ..., "new": ... } }`. **`null` bila tidak ada** yang tercatat. Bentuknya JSON bebas — tangani secara defensif di UI. |
| `waktu` | Waktu perubahan terjadi. |

## `GET /api/v1/audit-log/{id}`

**Path parameter:** `id` (int). Mengembalikan satu entri, bentuknya **identik** dengan item list.

## Kode Status — Audit Log

| Status | Keterangan |
| --- | --- |
| `200` | List/detail berhasil. |
| `400` | Parameter tanggal tidak valid (`date_from`/`date_to` bukan `YYYY-MM-DD`). |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `AUDIT_TRAIL`. |
| `404` | Entri dengan `id` tersebut tidak ada. |
| `500` | Kegagalan server/database. |

---

# Modul: Konfigurasi Sistem

Registry key-value global (`sys_config`) — daftar setting tetap hasil seeding yang dibaca di
berbagai bagian sistem (mis. `prefix_kode_proyek`, `prefix_nomor_surat`). **Hanya `value` yang bisa
diubah**; tidak ada create/delete karena kumpulan key sudah pasti sejak build skema.

**Base URL:** `/api/v1/konfigurasi-sistem` · **Modul RBAC:** `KONFIGURASI_SISTEM`

**Kuncinya adalah `key` (string), bukan id numerik.** Path parameter berupa nama key.

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/konfigurasi-sistem` | Semua setting (tanpa paginasi) |
| GET | `/api/v1/konfigurasi-sistem/{key}` | Detail satu setting |
| PUT | `/api/v1/konfigurasi-sistem/{key}` | Mengubah `value` sebuah setting |

## `GET /api/v1/konfigurasi-sistem`

**Query parameter**

| Parameter | Tipe | Keterangan |
| --- | --- | --- |
| `search` | string | Cocokkan sebagian pada `key`/`deskripsi`. |

**Tanpa paginasi** — `data` berisi seluruh setting, `meta.pagination` tidak ada.

**Contoh request**

```http
GET /api/v1/konfigurasi-sistem?search=prefix
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar konfigurasi sistem berhasil diambil",
  "data": [
    {
      "key": "prefix_kode_proyek",
      "value": "PRJ",
      "deskripsi": "Prefiks untuk kode proyek yang di-generate",
      "updatedAt": "2026-03-01T04:00:00.000Z",
      "updatedBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    },
    {
      "key": "last_sync_at",
      "value": null,
      "deskripsi": "Waktu sinkronisasi user WSO2 IS terakhir",
      "updatedAt": null,
      "updatedBy": null
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T07:30:00.000Z" }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `key` | Kunci unik setting (primary key). Tidak bisa diubah. |
| `value` | Nilai setting. **Bisa `null`** — beberapa key (mis. `last_sync_at`) memang mulai kosong. |
| `deskripsi` | Label sistem, read-only dari API. |
| `updatedAt` / `updatedBy` | `null` bila belum pernah diubah. |

## `GET /api/v1/konfigurasi-sistem/{key}`

**Path parameter:** `key` (string). Mengembalikan satu setting, bentuknya **identik** dengan item list.

**Contoh request**

```http
GET /api/v1/konfigurasi-sistem/prefix_kode_proyek
Authorization: Bearer <accessToken>
```

## `PUT /api/v1/konfigurasi-sistem/{key}`

Mengubah `value` sebuah setting. **Hanya `value` yang editable** — `deskripsi` dan `key` tidak.

**Path parameter:** `key` (string).

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `value` | string \| null | **ya** (boleh `null`) | Nilai baru; kirim `null` untuk mengosongkan (valid untuk setting nullable). |

Field `value` harus ada di body, tetapi `null` adalah nilai yang sah — berbeda dari menghilangkannya.

**Contoh request**

```http
PUT /api/v1/konfigurasi-sistem/prefix_kode_proyek
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "value": "SWA" }
```

**Response — 200:** setting setelah diperbarui (bentuk sama dengan GET detail), `message` =
`"Konfigurasi sistem berhasil diperbarui"`.

Perubahan berdampak langsung pada perilaku sistem. Contoh: mengubah `prefix_kode_proyek` memengaruhi
kode proyek yang di-generate **berikutnya** — kode proyek lama tidak ikut berubah. Konfirmasikan ke
user sebelum menyimpan setting yang memengaruhi penomoran.

## Kode Status — Konfigurasi Sistem

| Status | Keterangan |
| --- | --- |
| `200` | List/detail/update berhasil. |
| `400` | Body tidak valid (field `value` tidak ada). |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `KONFIGURASI_SISTEM`. |
| `404` | Key tersebut tidak ada di registry. |
| `500` | Kegagalan server/database. |
