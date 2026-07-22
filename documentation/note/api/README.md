# Dokumentasi API — Referensi Frontend

Referensi integrasi REST API **Swamedia Project Website Portal** untuk tim Frontend.
Semua yang ada di sini diambil langsung dari kode (`main.bal`, `modules/models/models.bal`),
bukan dari spesifikasi terpisah, sehingga selalu mencerminkan perilaku backend yang berjalan.

Base URL default: `http://localhost:9090` (lihat `Config.toml` → `port`).
Seluruh endpoint diawali prefix `/api/v1`.

## Daftar Modul

| # | Dokumen | Modul yang dibahas |
| --- | --- | --- |
| 1 | [01-autentikasi.md](01-autentikasi.md) | Auth (BFF WSO2 IS): init, login, token, refresh, userinfo, introspect, revoke, logout |
| 2 | [02-dashboard-dan-self-service.md](02-dashboard-dan-self-service.md) | Dashboard, Profil Saya, Akun Saya, Menu Saya, Notifikasi |
| 3 | [03-master-data.md](03-master-data.md) | Unit, Industri, Tags, Resource Tags, Kategori Surat, Kategori Finansial Keluar, Jabatan, Karyawan, Customer, Contact, Resource Unit |
| 4 | [04-rbac.md](04-rbac.md) | Role, Menu, Modul, Role Permission, Role Menu, Manajemen User |
| 5 | [05-sales-unit.md](05-sales-unit.md) | Proyek (+ Unit Share, Team Member, Proyek Tags), Kontrak Payung, Kontrak Biasa, Target Revenue Unit, Revenue Unit, Target Sales Unit, Sales Matrix |
| 6 | [06-finansial.md](06-finansial.md) | Tagihan (+ Pencairan), Pembayaran, Pengeluaran Perusahaan, Saldo Awal Kas, Cashflow |
| 7 | [07-e-office.md](07-e-office.md) | Daftar Surat (nomor surat otomatis) |
| 8 | [08-administrasi.md](08-administrasi.md) | Audit Log, Konfigurasi Sistem |

Dokumen ini (README) memuat aturan yang **berlaku di semua modul**. Baca bagian ini dulu —
dokumen per modul tidak mengulang hal-hal di bawah.

---

## 1. Envelope Response

Setiap response — sukses maupun error — dibungkus envelope yang sama:

```json
{
  "success": true,
  "message": "Daftar unit berhasil diambil",
  "data": [ ... ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-17T10:12:03.123Z",
    "pagination": { "page": 1, "limit": 20, "totalItems": 13, "totalPages": 1 }
  }
}
```

| Field | Tipe | Keterangan |
| --- | --- | --- |
| `success` | boolean | `true` bila request berhasil, `false` bila gagal. Pakai ini (atau HTTP status) sebagai penentu cabang, bukan isi `data`. |
| `message` | string | Pesan siap tampil ke user, berbahasa Indonesia. |
| `data` | any | Payload. Objek untuk endpoint detail, array untuk endpoint list, `null` untuk aksi tanpa hasil (delete, mark-as-read) dan untuk semua response error. |
| `errors` | object \| null | `null` saat sukses. Saat gagal berisi `{ code, message, details? }`. |
| `meta.timestamp` | string | Waktu response dibuat (UTC, ISO 8601). |
| `meta.pagination` | object | **Hanya ada di endpoint list berpaginasi.** Lihat bagian Paginasi. |

Bentuk response error:

```json
{
  "success": false,
  "message": "Unit dengan id 99 tidak ditemukan",
  "data": null,
  "errors": {
    "code": "NOT_FOUND",
    "message": "Unit dengan id 99 tidak ditemukan"
  },
  "meta": { "timestamp": "2026-07-17T10:12:03.123Z" }
}
```

`errors.message` selalu sama dengan `message` di level atas — cukup baca salah satu.
`errors.code` adalah kode mesin (SCREAMING_SNAKE_CASE) yang stabil; **pakai `errors.code`
untuk logika, `message` untuk ditampilkan.**

## 2. Konvensi Penamaan Field

Ini sumber kesalahan paling umum saat integrasi, jadi diperjelas di depan:

* **Response body & request body → `camelCase`** (`namaUnit`, `kodeProyek`, `nilaiTagihan`).
* **Query parameter → `snake_case`** (`unit_id`, `kategori_surat_id`, `is_read`, `date_from`).
* Path parameter memakai nama apa adanya (`{id}`, `{roleId}`, `{subjectId}`, `{key}`).

Pengecualian: `page` dan `limit` (satu kata, tidak berubah).

## 3. Autentikasi

Kecuali `/api/v1/dashboard/summary` dan seluruh `/api/v1/auth/*`, **semua endpoint wajib
mengirim access token**:

```http
Authorization: Bearer <accessToken>
```

Token divalidasi backend secara deklaratif terhadap JWKS WSO2 IS (signature, expiry, issuer,
audience) plus pengecekan keanggotaan grup aplikasi, sebelum resource-nya dijalankan. Token yang
sudah di-`revoke`/`logout` ditolak lewat denylist lokal meski secara kriptografis masih valid.

Konsekuensi untuk frontend:
* Token kedaluwarsa/di-logout → **401**. Jalankan refresh token, lalu ulangi request; kalau
  refresh juga gagal, arahkan ke halaman login.
* Field audit (`createdBy`, `updatedBy`) diisi backend dari klaim `sub` token. **Jangan pernah
  mengirimnya di body** — akan diabaikan.
* Setiap Create/Update/Delete yang berhasil di modul bisnis **otomatis mencatat jejak ke
  `audit_log`** (pelaku = `sub` token). Frontend tidak perlu melakukan apa pun untuk ini; jejaknya
  dibaca lewat modul [Audit Log](08-administrasi.md#modul-audit-log).

## 4. Otorisasi (RBAC)

Sebagian besar modul dijaga matriks permission per role (lihat [04-rbac.md](04-rbac.md)). Aksi
yang dibutuhkan diturunkan dari HTTP method:

| Method / path | Permission yang dicek |
| --- | --- |
| `GET` | `canRead` |
| `POST` | `canCreate` |
| `PUT` / `PATCH` | `canUpdate` |
| `DELETE` | `canDelete` |
| path mengandung `/approve` atau `/reject` | `canApprove` |
| path mengandung `/export` | `canExport` |

Role tanpa bit yang diperlukan → **403 FORBIDDEN**, sebelum request menyentuh business logic.

Modul yang **tidak** dijaga RBAC (cukup token valid): `tags`, `jabatan`, `profil-saya`,
`menu-saya`, `notifikasi` — data referensi bersama atau self-service yang di-scope ke pemanggil.

Untuk menyembunyikan menu/tombol sesuai hak akses, ambil [Menu Saya](02-dashboard-dan-self-service.md#modul-menu-saya)
saat login, bukan menebak dari role code.

## 5. Paginasi

Endpoint list berpaginasi menerima dua query parameter:

| Parameter | Tipe | Default | Keterangan |
| --- | --- | --- | --- |
| `page` | int | `1` | Nomor halaman, berbasis 1. |
| `limit` | int | `20` | Jumlah baris per halaman. |

`data` berisi **array item halaman itu saja**; jumlah totalnya ada di `meta.pagination`:

```json
"pagination": { "page": 2, "limit": 20, "totalItems": 137, "totalPages": 7 }
```

Endpoint yang **tidak** berpaginasi (mengembalikan seluruh baris sekaligus, tanpa
`meta.pagination`): semua `/tree`, semua `/dropdown`, `/api/v1/master/jabatan`,
`/api/v1/master/modul`, `/api/v1/konfigurasi-sistem`, dan seluruh endpoint chart/report.

## 6. Kode Status HTTP

Berlaku untuk semua modul; dokumen per modul hanya menambahkan arti spesifiknya.

| Status | `errors.code` | Kapan muncul |
| --- | --- | --- |
| `200 OK` | — | GET, PUT, DELETE berhasil. |
| `201 Created` | — | POST berhasil membuat data baru. Body berisi baris yang baru dibuat. |
| `400 Bad Request` | `VALIDATION_ERROR` | Body/parameter tidak lolos validasi: field wajib kosong, format tanggal salah, nilai ≤ 0, enum tak dikenal, atau aturan bisnis dilanggar. |
| `401 Unauthorized` | `UNAUTHORIZED` | Header `Authorization` tidak ada/salah format, token invalid, kedaluwarsa, atau sudah di-revoke. |
| `403 Forbidden` | `FORBIDDEN` | Token valid, tetapi role pemanggil tidak punya permission untuk aksi tersebut. |
| `404 Not Found` | `NOT_FOUND` | Data yang dirujuk tidak ada atau sudah di-soft-delete. |
| `409 Conflict` | `CONFLICT` | Melanggar keunikan (kode/nomor sudah dipakai) atau data masih direferensikan baris lain sehingga tak bisa dihapus. |
| `500 Internal Server Error` | `INTERNAL_ERROR` | Kegagalan tak terduga (DB down, dsb). Pesan selalu digeneralisasi — detail hanya masuk log server. |

Catatan **400 vs 409**: `VALIDATION_ERROR` berarti body-nya sendiri bermasalah (perbaiki lalu
kirim ulang). `CONFLICT` berarti body-nya sah tetapi bertabrakan dengan data yang sudah ada
(butuh keputusan user). Keduanya layak ditampilkan apa adanya — pesannya sudah berbahasa Indonesia.

## 7. Konvensi Data

* **Tanggal** (`tanggal`, `tanggalKontrak`, `tglMulai`, …): string `YYYY-MM-DD`.
* **Timestamp** (`createdAt`, `updatedAt`, `waktu`, `readAt`): string ISO 8601 UTC.
* **Uang & persentase** (`nilaiProyek`, `targetTw1`, `pencapaianPersen`, …): number desimal.
  Untuk nilai rupiah besar, parse sebagai desimal — jangan andalkan pembulatan float saat
  menampilkan.
* **`status` vs soft delete**: `TIDAK_AKTIF` artinya baris masih ada dan valid untuk data lama,
  hanya tidak boleh dipilih untuk entri **baru**. Soft delete (`DELETE`) menyembunyikannya
  sepenuhnya dari semua endpoint.
* **Semantik PUT = full replace.** PUT mengganti seluruh field yang bisa diubah. Field opsional
  yang dihilangkan dari body akan **dikosongkan**, bukan dipertahankan. Selalu kirim objek utuh —
  pola aman: GET detail → ubah field → PUT hasilnya.
* **Field read-only diabaikan diam-diam.** Nilai yang dihasilkan backend (`kodeProyek`, `nomor`,
  `nilaiBersih`, `isDefault`, `tanggalDeal`, field audit) diterima tanpa error bila dikirim, tapi
  tidak pernah diterapkan. Jangan andalkan pengiriman nilai tersebut.

## 8. CORS

Origin yang diizinkan dikonfigurasi di `config:corsAllowedOrigins` (lihat `Config.toml`).
Preflight `OPTIONS` selalu lolos tanpa auth. `allowCredentials: true`, sehingga origin frontend
harus terdaftar eksplisit — wildcard `*` tidak berlaku.
