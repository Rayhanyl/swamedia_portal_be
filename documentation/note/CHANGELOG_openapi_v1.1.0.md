# Changelog — Swamedia Portal OpenAPI v1.0.0 → v1.1.0

Semua perubahan diverifikasi langsung terhadap `swamedia_portal_schema_v2.sql` dan
`PRD_Swamedia_Project_Portal.docx` sebelum diterapkan. File final: `swamedia_portal_openapi_v1.1.0.yaml`
(YAML valid, 33 paths, 62 schemas).

---

## 🔴 Blocker — selesai (4/4)

### 1. Karyawan.jabatan → FK
- **Request** (`KaryawanCreateRequest`/`UpdateRequest`): `jabatan: string` → **`jabatanId: integer` (wajib)**.
  `jabatan_id` di DB adalah `NOT NULL` — bukan opsional seperti implementasi lama.
- **Response** (`KaryawanListItem`/`Detail`): `jabatan` sekarang object `{id, namaJabatan, kategori}` (skema baru `JabatanRef`), selalu terisi.
- **Endpoint baru:** `GET /api/v1/master/jabatan` (sumber dropdown, filter `search`/`status`, tidak dipaginasi).
- **Breaking change** — FE wajib migrasi form Karyawan dari text-input jabatan ke dropdown `jabatanId`.

### 2. Unit — `kodeUnit` & `tipeUnit`
- Ditambahkan ke `Unit`, `UnitTreeNode` (response) — `tipeUnit` computed read-only (STRUKTURAL/OPERASIONAL).
- **Temuan tambahan di luar laporan awal:** `kode_unit` di DB bersifat `NOT NULL UNIQUE`, tapi `UnitCreateRequest`/`UnitUpdateRequest` **sama sekali tidak punya field ini** — setiap create unit pasti gagal insert. Sudah ditambahkan sebagai field wajib di kedua request, plus contoh error 400 (kosong/panjang) dan 409 (duplikat kode).

### 3. Enum `jenisCustomer`
- Ditambahkan `enum: [ENTERPRISE, BANKING, BUMN, GOVERNMENT]` ke 4 skema Customer (sebelumnya *tidak ada enum sama sekali*, bukan cuma salah nilai).
- Semua contoh `Korporat` (6 lokasi) diganti `ENTERPRISE`.
- Ditambahkan filter query `jenis_customer` pada `GET /api/v1/master/customers` (sebelumnya hanya `status_peluang`).

### 4. Dashboard — 4 KPI
- `DashboardSummary`: `proyekSedangDikerjakan` → **`targetSalesSisa` + `posisiKas`** (total jadi 4 KPI: totalProyek, revenueBulanIni, targetSalesSisa, posisiKas), sumber `v_posisi_kas` & `target_sales_unit`/`v_realisasi_sales_tw`.
- ⚠️ **Perlu konfirmasi bisnis:** endpoint ini `security: []` (publik, sebelum login). `posisiKas`/`targetSalesSisa` adalah data finansial perusahaan — perlu keputusan apakah tetap publik atau dipindah ke belakang login.
- **Tidak diimplementasikan** (lihat "Di luar cakupan" di bawah): Tren Revenue 6 bulan, Daftar 5 proyek terbaru.

---

## 🟡 Perlu Perbaikan — 3 dari 5 dikerjakan, 2 dikoreksi

| # | Item di laporan Anda | Status | Catatan |
|---|---|---|---|
| 1 | RBAC (403 belum diterapkan) | ✅ Dikerjakan (Unit + Karyawan) | Extension `x-roles-allowed` ditambahkan di 13 operation (6 Unit + 1 Jabatan + 6 Karyawan) berdasarkan Role Permission Matrix resmi. Ini kontrak/dokumentasi — enforcement runtime tetap tugas backend Ballerina. **Modul lain (Customer, Proyek, dst.) belum dianotasi.** |
| 2 | Pagination `totalItems` vs `total` tidak konsisten | ❌ **Tidak ditemukan** | Saya cek seluruh 8 endpoint list di kontrak ini — semuanya konsisten pakai `totalItems`, tidak ada satupun yang pakai `total`. Kemungkinan ini merujuk ke kode FE/dokumen lain yang tidak saya akses. Tidak saya ubah karena tidak ada bukti di kontrak API. |
| 3 | Kategori Surat: validasi hapus `isDefault` + filter aktif | ⚠️ **Sebagian salah** | Validasi tolak-hapus-jika-`isDefault` **sudah ada dan sudah benar** (409 CONFLICT, bukan 400) — tidak perlu diubah. Yang **benar-benar hilang**: field `status` (AKTIF/TIDAK_AKTIF) sama sekali tidak ada di kontrak API padahal kolomnya ada di DB (`NOT NULL DEFAULT 'AKTIF'`). Sudah ditambahkan ke schema + filter `?status=` di endpoint list. |
| 4 | Unit Tree belum ada `kodeUnit` | ✅ Dikerjakan | Tercakup dalam perbaikan Blocker #2 (`UnitTreeNode`). |
| 5 | Endpoint dropdown Karyawan | ✅ Dikerjakan | `GET /api/v1/master/karyawan/dropdown` (`{id, nama, unitNama}`, tanpa pagination). |

---

## Di luar cakupan revisi ini (perlu keputusan/konfirmasi Anda)

- **Tren Revenue 6 bulan** & **Daftar 5 proyek terbaru** (disebut di laporan Anda untuk Dashboard) — saya cek PRD v2 tidak punya FR spesifik untuk Dashboard (hanya disebut sebagai nama menu di Bab 4). Tidak saya tambahkan ke schema karena tidak bisa saya verifikasi sebagai keputusan PRD yang terkonfirmasi — supaya tidak menambah scope yang belum disepakati stakeholder.
- **RBAC untuk 22 modul lain** di luar Unit/Karyawan — matriks lengkap sudah ada di dokumen Role & Permission, tinggal direplikasi dengan pola `x-roles-allowed` yang sama. Bisa saya lanjutkan kapan saja.
- **Dashboard publik pre-login** menampilkan data finansial — flag keputusan bisnis, bukan bug teknis.

---

## File

- `swamedia_portal_openapi_v1.1.0.yaml` — kontrak API final, tervalidasi (`yaml.safe_load` OK).
