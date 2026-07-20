# Modul: Finansial

Lima modul keuangan: penagihan (Tagihan + Pencairan), pengeluaran (Pembayaran & Pengeluaran
Perusahaan dengan alur approval), saldo kas (Saldo Awal Kas), dan laporan (Cashflow).

> Baca [README.md](README.md) dulu untuk envelope response dan kode status yang berlaku umum.
> Kategori pengeluaran (`kategoriId`) berasal dari
> [Kategori Finansial Keluar](03-master-data.md#modul-kategori-finansial-keluar).

## Ringkasan Modul

| Modul | Base URL | Modul RBAC | Sifat |
| --- | --- | --- | --- |
| [Tagihan](#modul-tagihan) | `/api/v1/finance/tagihan` | `TAGIHAN` | CRUD + status history + sub-resource Pencairan |
| [Pencairan](#sub-resource-pencairan) | `/api/v1/finance/tagihan/{tagihanId}/pencairan` | `PENCAIRAN` | Sub-resource Tagihan |
| [Pembayaran](#modul-pembayaran) | `/api/v1/finance/pembayaran` | `PEMBAYARAN` | CRUD + approve/reject |
| [Pengeluaran Perusahaan](#modul-pengeluaran-perusahaan) | `/api/v1/finance/pengeluaran-perusahaan` | `PENGELUARAN_PERUSAHAAN` | CRUD + approve/reject |
| [Saldo Awal Kas](#modul-saldo-awal-kas) | `/api/v1/finance/saldo-awal-kas` | `SALDO_AWAL_KAS` | Append-only + posisi kas |
| [Cashflow](#modul-cashflow) | `/api/v1/business/cashflow` | `CASHFLOW` | Laporan read-only |

**Semua nilai uang bertipe `decimal`.** Kirim sebagai angka JSON (mis. `15000000.00`), bukan string.

---

# Modul: Tagihan

Tagihan (invoice) per proyek, dengan siklus status penagihan dan sub-resource Pencairan (realisasi
kas bertahap).

**Base URL:** `/api/v1/finance/tagihan` · **Modul RBAC:** `TAGIHAN`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/finance/tagihan` | List tagihan berpaginasi |
| GET | `/api/v1/finance/tagihan/{id}` | Detail tagihan |
| GET | `/api/v1/finance/tagihan/{id}/status-history` | Riwayat perubahan status |
| POST | `/api/v1/finance/tagihan` | Membuat tagihan |
| PUT | `/api/v1/finance/tagihan/{id}` | Mengubah tagihan |
| DELETE | `/api/v1/finance/tagihan/{id}` | Soft delete |
| — | `.../{tagihanId}/pencairan…` | [Sub-resource Pencairan](#sub-resource-pencairan) |

## `GET /api/v1/finance/tagihan`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `search` | string | — | Cocokkan sebagian pada `noTagihan`. |
| `proyek_id` | int | — | Filter tagihan milik proyek tertentu. |
| `status_aktif` | string | — | Filter status penagihan. |
| `page` | int | `1` | Nomor halaman. |
| `limit` | int | `20` | Baris per halaman. |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar tagihan berhasil diambil",
  "data": [
    {
      "id": 88,
      "proyekId": 45,
      "proyekKode": "DB-2026-045",
      "proyekNama": "Migrasi Core Banking",
      "tanggalTagihan": "2026-07-05",
      "noTagihan": "INV/2026/07/0088",
      "keterangan": "Termin 1",
      "statusAktif": "KIRIM_TAGIHAN",
      "nilaiTagihan": 500000000.00,
      "nilaiDpp": 450450450.45,
      "ppn": 49549549.55,
      "pph": 0.00,
      "totalPencairan": 200000000.00
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T08:00:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 12, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `proyekKode` / `proyekNama` | Hasil join dari Proyek, read-only. |
| `statusAktif` | Siklus penagihan: `PELUANG`, `RENCANA`, `BAST`, `KIRIM_TAGIHAN`, `LUNAS`, `TIDAK_TERTAGIH`. Setiap perubahan dicatat ke riwayat status. |
| `nilaiTagihan` | Nilai tagihan. Total pencairan tak boleh melebihi ini. |
| `nilaiDpp` / `ppn` / `pph` | Rincian pajak (opsional, bisa `null`). |
| `totalPencairan` | **Terhitung backend** — jumlah pencairan yang tidak dibatalkan (status `PARSIAL`/`FINAL`). Read-only. Sisa tagihan = `nilaiTagihan - totalPencairan`. |

Field audit hanya ada di response detail.

## `GET /api/v1/finance/tagihan/{id}/status-history`

Riwayat transisi status (terbaru dulu). **Read-only** — ditulis backend saat tagihan dibuat dan
setiap kali `statusAktif` berubah.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Riwayat status tagihan berhasil diambil",
  "data": [
    {
      "id": 210,
      "tagihanId": 88,
      "status": "KIRIM_TAGIHAN",
      "tanggal": "2026-07-06",
      "keterangan": "Invoice dikirim ke customer",
      "createdAt": "2026-07-06T03:00:00.000Z",
      "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    },
    {
      "id": 205,
      "tagihanId": 88,
      "status": "RENCANA",
      "tanggal": "2026-07-05",
      "keterangan": null,
      "createdAt": "2026-07-05T02:00:00.000Z",
      "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T08:05:00.000Z" }
}
```

## `POST /api/v1/finance/tagihan`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `proyekId` | int | ya | Proyek pemilik tagihan. |
| `tanggalTagihan` | string | ya | Tanggal invoice (`YYYY-MM-DD`). |
| `noTagihan` | string | ya | Nomor invoice unik (maks 50 karakter). |
| `keterangan` | string \| null | tidak | Catatan. |
| `statusAktif` | string | tidak | Default `"RENCANA"`. |
| `nilaiTagihan` | decimal | ya | Nilai tagihan (> 0). |
| `nilaiDpp` | decimal \| null | tidak | Dasar pengenaan pajak. |
| `ppn` | decimal \| null | tidak | Nilai PPN. |
| `pph` | decimal \| null | tidak | Nilai PPh. |

`totalPencairan` tidak diterima (terhitung). Status awal selalu dicatat ke riwayat.

**Contoh request**

```http
POST /api/v1/finance/tagihan
Authorization: Bearer <accessToken>
Content-Type: application/json

{
  "proyekId": 45,
  "tanggalTagihan": "2026-07-05",
  "noTagihan": "INV/2026/07/0088",
  "nilaiTagihan": 500000000.00,
  "keterangan": "Termin 1"
}
```

**Response — 201:** tagihan baru, `message` = `"Tagihan berhasil dibuat"`.

## `PUT /api/v1/finance/tagihan/{id}`

**Body** — sama dengan POST, plus `statusKomentar`:

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `proyekId` | int | ya | Proyek pemilik. |
| `tanggalTagihan` | string | ya | Tanggal invoice. |
| `noTagihan` | string | ya | Nomor invoice unik. |
| `keterangan` | string \| null | tidak | Catatan. |
| `statusAktif` | string | ya | Status penagihan. |
| `statusKomentar` | string \| null | tidak | Catatan yang dicatat ke riwayat **saat status berubah** (diabaikan bila status tidak berubah). |
| `nilaiTagihan` | decimal | ya | Nilai tagihan (> 0). |
| `nilaiDpp` / `ppn` / `pph` | decimal \| null | tidak | Rincian pajak. |

**Response — 200:** tagihan setelah diperbarui.

## `DELETE /api/v1/finance/tagihan/{id}`

Soft delete. Response `data: null`.

## Kode Status — Tagihan

| Status | Keterangan |
| --- | --- |
| `200` | List/detail/history/update/delete berhasil. |
| `201` | Tagihan berhasil dibuat. |
| `400` | Body tidak valid (mis. `nilaiTagihan` ≤ 0, format tanggal salah). |
| `401` | Token tidak ada, kedaluwarsa, atau sudah di-logout/revoke. |
| `403` | Role pemanggil tidak punya izin `TAGIHAN`. |
| `404` | Tagihan/`proyekId` tidak ditemukan. |
| `409` | `noTagihan` sudah dipakai tagihan lain. |
| `500` | Kegagalan server/database. |

---

## Sub-resource: Pencairan

Realisasi kas (cash-in) sebuah tagihan — sebuah tagihan bisa cair bertahap, jadi punya beberapa
pencairan. **Modul RBAC-nya `PENCAIRAN`** (berbeda dari tagihan induknya), meski path-nya bersarang.

Tabel ini **tidak punya kolom audit update** (hanya `createdAt`/`createdBy`).

### Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/finance/tagihan/{tagihanId}/pencairan` | Semua pencairan sebuah tagihan |
| POST | `/api/v1/finance/tagihan/{tagihanId}/pencairan` | Menambah pencairan |
| PUT | `/api/v1/finance/tagihan/{tagihanId}/pencairan/{id}` | Mengubah pencairan |
| DELETE | `/api/v1/finance/tagihan/{tagihanId}/pencairan/{id}` | Soft delete pencairan |

### `GET .../{tagihanId}/pencairan`

**Path parameter:** `tagihanId` (int). Mengembalikan daftar (tanpa paginasi).

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar pencairan berhasil diambil",
  "data": [
    {
      "id": 15,
      "tagihanId": 88,
      "tanggalPencairan": "2026-07-15",
      "nilai": 200000000.00,
      "status": "PARSIAL",
      "keterangan": "Pencairan termin 1 sebagian",
      "createdAt": "2026-07-15T06:00:00.000Z",
      "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T08:10:00.000Z" }
}
```

| Field | Keterangan |
| --- | --- |
| `status` | `PARSIAL` (cair sebagian), `FINAL` (pelunasan), `DIBATALKAN`. Hanya `PARSIAL`/`FINAL` yang dihitung ke `totalPencairan` tagihan. |
| `nilai` | Nilai yang dicairkan (> 0). |

### `POST` / `PUT`

**Path parameter:** `tagihanId` (int); untuk PUT juga `id` (int).

**Body** (sama untuk keduanya):

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `tanggalPencairan` | string | ya | Tanggal pencairan (`YYYY-MM-DD`). |
| `nilai` | decimal | ya | Nilai dicairkan (> 0). |
| `status` | string | ya | `PARSIAL` / `FINAL` / `DIBATALKAN`. |
| `keterangan` | string \| null | tidak | Catatan. |

**Aturan penting:** total pencairan yang tidak dibatalkan **tidak boleh melebihi `nilaiTagihan`**.
Melanggarnya menghasilkan `400`/`409`.

**Contoh request**

```http
POST /api/v1/finance/tagihan/88/pencairan
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "tanggalPencairan": "2026-07-15", "nilai": 200000000.00, "status": "PARSIAL" }
```

**Response:** POST `201` (`"Pencairan berhasil ditambahkan"`), PUT/DELETE `200`.

### Kode Status — Pencairan

| Status | Keterangan |
| --- | --- |
| `200` | List/update/delete berhasil. |
| `201` | Pencairan berhasil ditambahkan. |
| `400` | `nilai` ≤ 0, atau total pencairan melebihi `nilaiTagihan`. |
| `401` | Token tidak valid. |
| `403` | Role pemanggil tidak punya izin `PENCAIRAN`. |
| `404` | Tagihan/pencairan tidak ditemukan. |
| `409` | Total pencairan melebihi `nilaiTagihan`. |
| `500` | Kegagalan server/database. |

---

# Modul: Pembayaran

Cash-out yang terkait proyek, melalui alur approval. **Base URL:** `/api/v1/finance/pembayaran` ·
**Modul RBAC:** `PEMBAYARAN`

## Alur Status (state machine)

```
PENGAJUAN --approve--> APPROVED   (terkunci; tidak bisa diedit)
    ^         --reject--> REJECTED
    |                        |
    +----- edit (PUT) -------+   (mengedit REJECTED mengembalikannya ke PENGAJUAN)
```

* Baris baru selalu lahir `PENGAJUAN`.
* Hanya baris `PENGAJUAN` atau `REJECTED` yang bisa diedit. **Mengedit baris `REJECTED`
  mengembalikannya ke `PENGAJUAN`.**
* Baris `APPROVED` **terkunci** — tidak bisa PUT/DELETE.
* `approve`/`reject` membutuhkan izin **`canApprove`** pada modul ini (lihat
  [Role Permission](04-rbac.md#modul-role-permission)).

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/finance/pembayaran` | List berpaginasi |
| GET | `/api/v1/finance/pembayaran/{id}` | Detail |
| POST | `/api/v1/finance/pembayaran` | Membuat (status `PENGAJUAN`) |
| PUT | `/api/v1/finance/pembayaran/{id}` | Mengubah (hanya `PENGAJUAN`/`REJECTED`) |
| PUT | `/api/v1/finance/pembayaran/{id}/approve` | Menyetujui |
| PUT | `/api/v1/finance/pembayaran/{id}/reject` | Menolak |
| DELETE | `/api/v1/finance/pembayaran/{id}` | Soft delete |

## `GET /api/v1/finance/pembayaran`

**Query parameter**

| Parameter | Tipe | Keterangan |
| --- | --- | --- |
| `search` | string | Cocokkan `keterangan`/nomor referensi. |
| `proyek_id` | int | Filter proyek. |
| `kategori_id` | int | Filter kategori finansial keluar. |
| `status` | string | `PENGAJUAN` / `APPROVED` / `REJECTED`. |
| `page` / `limit` | int | Paginasi (default `1` / `20`). |

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar pembayaran berhasil diambil",
  "data": [
    {
      "id": 30,
      "proyekId": 45,
      "proyekKode": "DB-2026-045",
      "proyekNama": "Migrasi Core Banking",
      "kategoriId": 2,
      "kategoriNama": "Operasional",
      "nilai": 15000000.00,
      "tanggalPengajuan": "2026-07-08",
      "tanggalRealisasi": null,
      "keterangan": "Sewa perangkat",
      "status": "PENGAJUAN",
      "approvedBy": null,
      "approvedAt": null,
      "catatanApproval": null
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T08:20:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 5, "totalPages": 1 }
  }
}
```

**Penjelasan field penting**

| Field | Keterangan |
| --- | --- |
| `proyekKode`/`proyekNama`, `kategoriNama` | Hasil join, read-only. |
| `status` | Status alur approval. |
| `tanggalRealisasi` | Tanggal kas benar-benar keluar; `null` sampai direalisasikan (biasanya diisi saat approve). |
| `approvedBy` / `approvedAt` / `catatanApproval` | Diisi oleh aksi approve/reject; `null` selagi masih `PENGAJUAN`. |

## `POST` / `PUT`

**Body** (sama; PUT hanya berlaku untuk baris `PENGAJUAN`/`REJECTED`):

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `proyekId` | int | ya | Proyek terkait. |
| `kategoriId` | int | ya | Kategori finansial keluar. |
| `nilai` | decimal | ya | Nilai pembayaran (> 0). |
| `tanggalPengajuan` | string | ya | Tanggal pengajuan (`YYYY-MM-DD`). |
| `tanggalRealisasi` | string \| null | tidak | Tanggal realisasi. |
| `keterangan` | string \| null | tidak | Catatan. |

`status`/`approvedBy`/`approvedAt` tidak diterima — dikendalikan alur. **Response:** POST `201`,
PUT `200`.

## `PUT /api/v1/finance/pembayaran/{id}/approve`

Menyetujui baris `PENGAJUAN`. Membutuhkan izin `canApprove`.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `tanggalRealisasi` | string \| null | tidak | Tanggal kas keluar yang dicatat saat approve (`YYYY-MM-DD`). |
| `catatan` | string \| null | tidak | Catatan persetujuan. |

**Contoh request**

```http
PUT /api/v1/finance/pembayaran/30/approve
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "tanggalRealisasi": "2026-07-18", "catatan": "Disetujui manajer keuangan" }
```

**Response — 200:** pembayaran dengan `status: "APPROVED"` beserta `approvedBy`/`approvedAt` terisi.

## `PUT /api/v1/finance/pembayaran/{id}/reject`

Menolak baris `PENGAJUAN`. Membutuhkan izin `canApprove`.

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `catatan` | string \| null | tidak | Alasan penolakan. |

**Response — 200:** pembayaran dengan `status: "REJECTED"`. Baris ini masih bisa direvisi (PUT), yang
mengembalikannya ke `PENGAJUAN`.

## Kode Status — Pembayaran

| Status | Keterangan |
| --- | --- |
| `200` | List/detail/update/approve/reject/delete berhasil. |
| `201` | Pembayaran berhasil dibuat. |
| `400` | Body tidak valid (mis. `nilai` ≤ 0). |
| `401` | Token tidak valid. |
| `403` | Tidak punya izin `PEMBAYARAN`; atau approve/reject tanpa `canApprove`. |
| `404` | Pembayaran/`proyekId`/`kategoriId` tidak ditemukan. |
| `409` | Transisi status tidak sah (mis. approve baris yang bukan `PENGAJUAN`, atau edit/hapus baris `APPROVED`). |
| `500` | Kegagalan server/database. |

---

# Modul: Pengeluaran Perusahaan

Kembaran Pembayaran, tetapi cash-out **internal yang terkait unit** (bukan proyek). **Alur status,
aturan edit, dan endpoint approve/reject persis sama** dengan Pembayaran — lihat
[state machine di atas](#alur-status-state-machine).

**Base URL:** `/api/v1/finance/pengeluaran-perusahaan` · **Modul RBAC:** `PENGELUARAN_PERUSAHAAN`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/finance/pengeluaran-perusahaan` | List berpaginasi |
| GET | `/api/v1/finance/pengeluaran-perusahaan/{id}` | Detail |
| POST | `/api/v1/finance/pengeluaran-perusahaan` | Membuat (status `PENGAJUAN`) |
| PUT | `/api/v1/finance/pengeluaran-perusahaan/{id}` | Mengubah (hanya `PENGAJUAN`/`REJECTED`) |
| PUT | `/api/v1/finance/pengeluaran-perusahaan/{id}/approve` | Menyetujui |
| PUT | `/api/v1/finance/pengeluaran-perusahaan/{id}/reject` | Menolak |
| DELETE | `/api/v1/finance/pengeluaran-perusahaan/{id}` | Soft delete |

## `GET /api/v1/finance/pengeluaran-perusahaan`

**Query parameter:** `search`, `unit_id` (int), `kategori_id` (int), `status`, `page`, `limit`.

**Perbedaan dari Pembayaran:** difilter dan dikaitkan ke **`unit_id`**, bukan `proyek_id`.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar pengeluaran berhasil diambil",
  "data": [
    {
      "id": 12,
      "unitId": 3,
      "unitNama": "Digital Business",
      "kategoriId": 2,
      "kategoriNama": "Operasional",
      "nilai": 7500000.00,
      "tanggalPengajuan": "2026-07-09",
      "tanggalRealisasi": null,
      "keterangan": "Pembelian lisensi tools",
      "status": "PENGAJUAN",
      "approvedBy": null,
      "approvedAt": null,
      "catatanApproval": null
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T08:30:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 3, "totalPages": 1 }
  }
}
```

Field sama dengan Pembayaran, kecuali `proyekId`/`proyekKode`/`proyekNama` diganti
`unitId`/`unitNama`.

## `POST` / `PUT`

**Body** (sama; PUT hanya untuk `PENGAJUAN`/`REJECTED`):

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `unitId` | int | ya | Unit yang menanggung pengeluaran. |
| `kategoriId` | int | ya | Kategori finansial keluar. |
| `nilai` | decimal | ya | Nilai pengeluaran (> 0). |
| `tanggalPengajuan` | string | ya | Tanggal pengajuan (`YYYY-MM-DD`). |
| `tanggalRealisasi` | string \| null | tidak | Tanggal realisasi. |
| `keterangan` | string \| null | tidak | Catatan. |

## `PUT .../{id}/approve` dan `.../{id}/reject`

**Body identik dengan Pembayaran** ([ApproveRequest](#put-apiv1financepembayaranidapprove) /
[RejectRequest](#put-apiv1financepembayaranidreject)):

* approve: `{ "tanggalRealisasi": "YYYY-MM-DD"?, "catatan": string? }`
* reject: `{ "catatan": string? }`

Keduanya butuh izin `canApprove` pada modul `PENGELUARAN_PERUSAHAAN`.

## Kode Status — Pengeluaran Perusahaan

Sama dengan [Pembayaran](#kode-status--pembayaran), dengan izin modul `PENGELUARAN_PERUSAHAAN` dan
`404` bila `unitId`/`kategoriId` tidak ditemukan.

---

# Modul: Saldo Awal Kas

Saldo kas awal, **append-only**: tidak ada update/delete. Koreksi dilakukan dengan menambah baris
baru bertanggal lebih akhir; posisi kas selalu berpatokan pada baris terbaru.

**Base URL:** `/api/v1/finance/saldo-awal-kas` · **Modul RBAC:** `SALDO_AWAL_KAS`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/finance/saldo-awal-kas/posisi-kas` | Posisi kas terkini (terhitung) |
| GET | `/api/v1/finance/saldo-awal-kas` | List saldo awal berpaginasi |
| GET | `/api/v1/finance/saldo-awal-kas/{id}` | Detail satu baris |
| POST | `/api/v1/finance/saldo-awal-kas` | Menambah baris saldo awal |

Tidak ada PUT/DELETE — sesuai sifat append-only.

## `GET /api/v1/finance/saldo-awal-kas/posisi-kas`

Posisi kas terkini yang dihitung dari view: berpatokan pada saldo awal terbaru, ditambah inflow
terealisasi (pencairan `PARSIAL`/`FINAL`) dan dikurangi outflow terealisasi (pembayaran +
pengeluaran yang `APPROVED` dan sudah punya tanggal realisasi), sejak tanggal patokan.

**Tidak ada parameter.**

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Posisi kas berhasil diambil",
  "data": {
    "tanggalSaldoAwal": "2026-01-01",
    "saldoAwal": 1000000000.00,
    "totalInflow": 200000000.00,
    "totalOutflow": 22500000.00,
    "posisiKas": 1177500000.00
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T08:40:00.000Z" }
}
```

**Penjelasan field**

| Field | Keterangan |
| --- | --- |
| `tanggalSaldoAwal` | Tanggal patokan (saldo awal terbaru). **`null` bila belum ada** saldo awal sama sekali. |
| `saldoAwal` | Nilai saldo awal di tanggal patokan; `null` bila belum ada. |
| `totalInflow` | Total inflow terealisasi sejak patokan (`0` bila belum ada patokan). |
| `totalOutflow` | Total outflow terealisasi sejak patokan (`0` bila belum ada patokan). |
| `posisiKas` | `saldoAwal + totalInflow - totalOutflow`; `null` bila belum ada saldo awal. |

Tangani semua field nullable sebagai "belum tersedia" di UI ketika belum ada saldo awal.

## `GET /api/v1/finance/saldo-awal-kas`

**Query parameter:** `page` (default `1`), `limit` (default `20`). Terurut terbaru dulu.

**Contoh response — 200 OK**

```json
{
  "success": true,
  "message": "Daftar saldo awal kas berhasil diambil",
  "data": [
    {
      "id": 2,
      "tanggal": "2026-01-01",
      "nilai": 1000000000.00,
      "keterangan": "Saldo awal tahun 2026",
      "createdAt": "2026-01-02T02:00:00.000Z",
      "createdBy": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T08:42:00.000Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 2, "totalPages": 1 }
  }
}
```

Tabel ini hanya punya `createdAt`/`createdBy` (tidak ada `updatedAt`/`updatedBy`), dan field itu
sudah muncul di list.

## `POST /api/v1/finance/saldo-awal-kas`

**Body**

| Field | Tipe | Wajib | Keterangan |
| --- | --- | --- | --- |
| `tanggal` | string | ya | Tanggal saldo (`YYYY-MM-DD`). |
| `nilai` | decimal | ya | Nilai saldo awal. |
| `keterangan` | string \| null | tidak | Catatan. |

**Contoh request**

```http
POST /api/v1/finance/saldo-awal-kas
Authorization: Bearer <accessToken>
Content-Type: application/json

{ "tanggal": "2026-01-01", "nilai": 1000000000.00, "keterangan": "Saldo awal tahun 2026" }
```

**Response — 201:** baris yang baru dibuat, `message` = `"Saldo awal kas berhasil dibuat"`.

## Kode Status — Saldo Awal Kas

| Status | Keterangan |
| --- | --- |
| `200` | Posisi kas/list/detail berhasil. |
| `201` | Saldo awal kas berhasil dibuat. |
| `400` | Body tidak valid (mis. format `tanggal` salah). |
| `401` | Token tidak valid. |
| `403` | Role pemanggil tidak punya izin `SALDO_AWAL_KAS`. |
| `404` | Baris dengan `id` tersebut tidak ada. |
| `500` | Kegagalan server/database. |

---

# Modul: Cashflow

Laporan arus kas bulanan **read-only** untuk satu tahun, seluruh perusahaan: inflow (dari pencairan)
vs outflow (dari pembayaran + pengeluaran yang `APPROVED` dan terealisasi).

**Base URL:** `/api/v1/business/cashflow` · **Modul RBAC:** `CASHFLOW`

## Daftar Endpoint

| Method | URL | Fungsi |
| --- | --- | --- |
| GET | `/api/v1/business/cashflow/chart` | Data chart 12 bulan (inflow vs outflow) |
| GET | `/api/v1/business/cashflow` | Laporan lengkap: 12 baris bulanan + total + posisi kas |

## `GET /api/v1/business/cashflow`

**Query parameter**

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `tahun` | int | **tahun berjalan** | Tahun laporan. |

**Contoh request**

```http
GET /api/v1/business/cashflow?tahun=2026
Authorization: Bearer <accessToken>
```

**Contoh response — 200 OK** (dipangkas sampai 2 bulan)

```json
{
  "success": true,
  "message": "Cashflow berhasil diambil",
  "data": {
    "tahun": 2026,
    "months": [
      { "bulan": 1, "label": "Jan", "inflow": 0.00, "outflow": 0.00, "net": 0.00 },
      { "bulan": 7, "label": "Jul", "inflow": 200000000.00, "outflow": 22500000.00, "net": 177500000.00 }
    ],
    "totalInflow": 200000000.00,
    "totalOutflow": 22500000.00,
    "netTotal": 177500000.00,
    "posisiKasTerkini": 1177500000.00
  },
  "errors": null,
  "meta": { "timestamp": "2026-07-17T08:50:00.000Z" }
}
```

**Penjelasan field**

| Field | Keterangan |
| --- | --- |
| `months[]` | **Selalu 12 baris** (Jan–Des), diisi `0` untuk bulan tanpa data. `net` = `inflow - outflow`. |
| `totalInflow` / `totalOutflow` / `netTotal` | Total setahun. |
| `posisiKasTerkini` | Posisi kas terkini dari view yang sama dengan endpoint posisi kas; **`null` bila belum ada saldo awal**. |

## `GET /api/v1/business/cashflow/chart`

Sama, tetapi hanya titik-titik bulanan untuk grafik — **tanpa** total dan posisi kas.

**Query parameter:** `tahun` (int, default tahun berjalan).

**Contoh response — 200 OK** (dipangkas)

```json
{
  "success": true,
  "message": "Chart cashflow berhasil diambil",
  "data": [
    { "bulan": 1, "label": "Jan", "inflow": 0.00, "outflow": 0.00 },
    { "bulan": 7, "label": "Jul", "inflow": 200000000.00, "outflow": 22500000.00 }
  ],
  "errors": null,
  "meta": { "timestamp": "2026-07-17T08:52:00.000Z" }
}
```

Selalu 12 titik (Jan–Des). Tidak ada field `net`/`posisiKas` — cukup `inflow` dan `outflow` per bulan.

## Kode Status — Cashflow

| Status | Keterangan |
| --- | --- |
| `200` | Laporan/chart berhasil diambil. |
| `400` | Parameter `tahun` tidak valid. |
| `401` | Token tidak valid. |
| `403` | Role pemanggil tidak punya izin `CASHFLOW`. |
| `500` | Kegagalan server/database. |
