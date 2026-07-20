# PROMPT CLAUDE CODE — API BISNIS SWAMEDIA PORTAL
# Fokus: modul bisnis yang BELUM ada di Ballerina yang sedang berjalan.
# Auth, Master Data, dan Daftar Surat sudah berjalan — jangan disentuh.
#
# CARA PAKAI:
# 1. Paste seluruh CONTEXT block di awal sesi Claude Code
# 2. Lanjutkan dengan satu blok [API-XX] per sesi
# 3. Selalu sebutkan modul yang sudah selesai saat memulai sesi berikutnya

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CONTEXT — PASTE DI AWAL SETIAP SESI CLAUDE CODE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Kamu melanjutkan pengembangan backend API Ballerina untuk Swamedia Project Website Portal
milik PT Swamedia Informatika. Sistem sudah berjalan sebagian — kamu hanya menambahkan
modul yang belum ada, mengikuti pola yang sudah ada di codebase.

═══════════════════════════════════════════════════════════
YANG SUDAH BERJALAN (JANGAN DIUBAH)
═══════════════════════════════════════════════════════════

  ✅ Auth BFF lengkap  → /api/v1/auth/*
     (login, refresh, logout, userinfo, introspect, revoke, init)

  ✅ Master Data       → /api/v1/master/*
     units, units/tree, industries, tags, resource-tags,
     kategori-surat, karyawan, customers, contacts

  ✅ Daftar Surat      → /api/v1/business/daftar-surat/*
     (CRUD + preview-nomor + cancel)

  ✅ Proyek dropdown   → /api/v1/business/proyek/dropdown
     (hanya dropdown — bukan CRUD lengkap)

  ✅ Dashboard summary → /api/v1/dashboard/summary

═══════════════════════════════════════════════════════════
YANG BELUM ADA (TARGET PROMPT INI)
═══════════════════════════════════════════════════════════

  ❌ Proyek CRUD lengkap + sub-resource
  ❌ Kontrak Payung & Kontrak Biasa
  ❌ Tagihan + Pencairan
  ❌ Pembayaran + Pengeluaran Perusahaan + Posisi Kas
  ❌ Target Sales & Revenue Unit
  ❌ Laporan (Sales Matrix, Pencapaian, Revenue per TW, Chart)
  ❌ Notifikasi
  ❌ Audit Log
  ❌ Resource Unit (CRUD — bukan dropdown)
  ❌ Jabatan Master + Project Role Master
  ❌ Kategori Finansial Keluar
  ❌ Manajemen User/Role (SCIM2 proxy)
  ❌ Sinkronisasi IS (reconciliation job)
  ❌ Konfigurasi Sistem (sys_config CRUD)

═══════════════════════════════════════════════════════════
ARSITEKTUR & POLA KODE (IKUTI YANG SUDAH ADA)
═══════════════════════════════════════════════════════════

  Stack     : Ballerina Swan Lake, PostgreSQL, WSO2 IS (via JWKS), WSO2 APIM
  Base path : /api/v1/
  Alur      : FE → APIM → Ballerina → DB
              FE → APIM → Ballerina → IS  (untuk IS API)

  Headers yang masuk ke Ballerina:
    Authorization: Bearer <access_token>   ← divalidasi Ballerina via JWKS
    apikey: <api_key>                       ← sudah divalidasi APIM, tidak perlu re-validasi

  Struktur folder (ikuti yang sudah ada):
    modules/{nama_modul}/
      {nama}_model.bal       ← record types spesifik modul ini
      {nama}_repository.bal  ← SQL queries ke PostgreSQL
      {nama}_service.bal     ← business logic, validasi, aturan bisnis
      {nama}_resource.bal    ← HTTP resource functions, role check

  File bersama yang sudah ada:
    types.bal       ← ApiResponse, ApiError, ResponseMeta, Pagination
    utils.bal       ← subjectFromAccessToken(), rolesFromToken(), hasRole(),
                      buildSuccess(), buildError(), buildPaged(), nowIso()
    middleware/auth_guard.bal       ← JWT validation
    middleware/audit_interceptor.bal ← writeAudit()

  JANGAN menduplikasi tipe atau fungsi yang sudah ada di file bersama itu.
  Import dari modul yang sudah ada menggunakan import swamedia/portal_api.{module}.

═══════════════════════════════════════════════════════════
KONVENSI WAJIB (SAMA SEPERTI YANG SUDAH ADA)
═══════════════════════════════════════════════════════════

  ── Response envelope (WAJIB semua endpoint) ──────────────
  {
    "success": true|false,
    "message": "...",
    "data": {...} | [...] | null,
    "errors": { "code": "...", "message": "...", "details": null } | null,
    "meta": { "timestamp": "ISO-8601", "pagination": {...} | null }
  }

  HTTP status ↔ success mapping:
    200/201 → success: true
    400     → success: false, code: BAD_REQUEST
    401     → success: false, code: UNAUTHORIZED (Catatan: guard Ballerina
              bisa return format native framework — bukan ApiResponse — ini normal)
    403     → success: false, code: FORBIDDEN
    404     → success: false, code: NOT_FOUND
    409     → success: false, code: CONFLICT
    500     → success: false, code: INTERNAL_ERROR

  ── Error handling ─────────────────────────────────────────
  WAJIB pola do/on fail di setiap service & repository:
    do {
        // logika
    } on fail var e {
        log:printError("Deskripsi error", 'error = e);
        return buildError(500, "INTERNAL_ERROR", "Terjadi kesalahan server");
    }

  ── Database ───────────────────────────────────────────────
  - Driver: ballerinax/postgresql
  - Parameterized query WAJIB (tidak boleh string concat untuk nilai user)
  - Semua query WHERE: AND is_deleted = false
  - Audit columns: created_by/updated_by = subject_id dari token
  - Soft delete: UPDATE SET is_deleted = true, updated_by = subject_id
  - TIDAK ada hard delete kecuali disebutkan eksplisit

  ── Pagination ─────────────────────────────────────────────
  Semua endpoint LIST: query params page (default 1), limit (default 20)
  meta.pagination wajib diisi: { page, limit, total, totalPages }

  ── Field naming ───────────────────────────────────────────
  JSON in/out : camelCase
  DB columns  : snake_case (mapping di repository)
  Jangan expose: is_deleted, created_at, updated_at di response publik
                 (kecuali diminta eksplisit)

  ── RBAC Roles (5 role resmi) ──────────────────────────────
  "Super Admin" | "Direktur" | "Manager" | "Assistant Manager" | "Finance"

  Matriks hak akses ringkas:
    Super Admin   → semua endpoint
    Direktur      → Read semua; CRUD: Surat, Resource Unit, Profil
    Manager       → CRUD: Karyawan, Proyek, Customer, Kontrak, Surat, Resource
    Asst. Manager → CRUD unit sendiri; DILARANG Export (403)
    Finance       → CRUD finansial: Tagihan, Pencairan, Pembayaran, Pengeluaran, Cashflow

  Export (Excel/CSV/PDF):
    Izin  : Super Admin, Direktur, Manager, Finance
    BLOKIR: Assistant Manager → return 403 FORBIDDEN

  ── Audit Trail ────────────────────────────────────────────
  Catat ke audit_log untuk entitas: proyek, tagihan, pencairan_tagihan,
  kontrak_payung, kontrak_biasa, karyawan, nomor_surat, customer,
  unit_share, team_member, pembayaran, pengeluaran_perusahaan, saldo_awal_kas,
  + aksi user management (meski datanya di IS)

  Function writeAudit sudah ada di middleware/audit_interceptor.bal.
  Call signature: writeAudit(dbClient, tableName, recordId, aksi, aktor, ip, perubahan?)
  Perubahan sebaiknya JSON string: {"sebelum": {...}, "sesudah": {...}}

═══════════════════════════════════════════════════════════
SKEMA DATABASE RINGKAS (referensi cepat)
═══════════════════════════════════════════════════════════

  Tabel & kolom kritis yang sering dirujuk:

  proyek: id, kode_proyek, customer_id, industri_id, unit_id,
    kontrak_payung_id, kontrak_biasa_id, nama_proyek, departemen,
    nilai_proyek, subkon, nilai_bersih [GENERATED AS nilai_proyek-subkon],
    pic_sales_id, pmo_id, no_kontrak, tanggal_kontrak, tanggal_bast,
    tanggal_mulai, tanggal_deal, target_selesai, status, tahun, is_deleted
    CHECK status IN ('INFO_PELUANG','UNDANGAN_PENJELASAN','MEETING_INISIASI',
                     'PROSES_PROPOSAL','EVALUASI_ADMIN_TEKNIS','DEAL_KONTRAK','GAGAL')
    ⚠️  Saat status → DEAL_KONTRAK: SET tanggal_deal = CURRENT_DATE
        dalam transaksi yang SAMA dengan INSERT log_status

  log_status: id, proyek_id, status, komentar, tanggal, is_deleted

  unit_share: id, proyek_id, unit_id, nilai_share, persentase, is_deleted

  team_member: id, proyek_id, karyawan_id, role_id [FK project_role_master],
    tgl_mulai, tgl_selesai, bobot, keterangan,
    undangan_status ['BELUM_DIKIRIM','TERKIRIM','GAGAL'],
    undangan_sent_at, undangan_sent_by, is_deleted
    UNIQUE (proyek_id, karyawan_id, tgl_mulai)

  kontrak_payung: id, customer_id, no_kontrak_payung, nama_kontrak,
    tanggal_kontrak NOT NULL, tanggal_mulai NOT NULL, tanggal_selesai NOT NULL
    VIEW v_kontrak_payung → tambah status_berlaku computed

  kontrak_payung_harga_role: id, kontrak_payung_id, role_id, tipe_harga, nilai
    CHECK tipe_harga IN ('PER_BULAN','PER_PROJECT')

  kontrak_biasa: id, kontrak_payung_id [nullable], customer_id,
    no_kontrak_biasa, nama_kontrak, tanggal_kontrak NOT NULL, nilai

  tagihan: id, proyek_id, tanggal_tagihan, no_tagihan, keterangan,
    status_aktif, nilai_tagihan, nilai_dpp, ppn, pph, is_deleted
    CHECK status_aktif IN ('RENCANA','BAST','KIRIM_TAGIHAN','LUNAS','PELUANG','TIDAK_TERTAGIH')
    ⚠️  TIDAK ADA kolom nilai_cair/tanggal_cair → dihitung dari pencairan_tagihan

  pencairan_tagihan: id, tagihan_id, tanggal_pencairan, nilai, status, keterangan, is_deleted
    CHECK status IN ('PARSIAL','FINAL','DIBATALKAN')
    CHECK nilai > 0

  status_tagihan: id, tagihan_id, status, tanggal, keterangan, is_deleted

  pembayaran: id, proyek_id, kategori_id, nilai, tanggal_pengajuan,
    tanggal_realisasi [nullable], keterangan,
    status ['PENGAJUAN','APPROVED','REJECTED'],
    approved_by, approved_at, catatan_approval, is_deleted

  pengeluaran_perusahaan: id, unit_id, kategori_id, nilai, tanggal_pengajuan,
    tanggal_realisasi [nullable], keterangan,
    status ['PENGAJUAN','APPROVED','REJECTED'],
    approved_by, approved_at, catatan_approval, is_deleted

  ⚠️  ATURAN APPROVAL (fn_unit_approver di DB):
      Jika unit pengaju = 11 (Finance) → approver harus Direktur Utama (unit 1)
      Selain itu → approver harus Finance
      Validasi: cek role user yang request vs aturan ini → 403 jika tidak sesuai

  ⚠️  Cash-out dihitung HANYA saat: status='APPROVED' AND tanggal_realisasi IS NOT NULL

  saldo_awal_kas: id, tanggal, nilai, keterangan, created_at, created_by
    APPEND-ONLY — tidak ada UPDATE/DELETE

  target_sales_unit: id, unit_id, tahun, target_tw1..tw4
    UNIQUE (unit_id, tahun)

  target_revenue_unit: id, unit_id, tahun, target_tw1..tw4
    UNIQUE (unit_id, tahun)

  project_role_master: id, nama_role, status
    15 nilai (sudah di-seed)

  jabatan_master: id, nama_jabatan, kategori, is_kombinasi_unit, status

  kategori_finansial_keluar: id, kode, nama, status

  notification: id, recipient_karyawan_id, kategori, judul, pesan,
    ref_table, ref_id, link_label, is_read, read_at
    CHECK kategori IN ('PENUGASAN','STATUS','SISTEM')

  notification_email_log: id, notification_id, email_tujuan, status, attempt_no, sent_at

  audit_log: id, table_name, record_id, aksi, aktor, ip_address, perubahan, waktu
    APPEND-ONLY

  user_cache: subject_id PK, nama, email, status, last_synced_at
    READ-ONLY (hanya sync job & login yang boleh write)

  Views yang sudah ada di DB (gunakan langsung, jangan compute manual):
    v_unit                  → unit + tipe_unit (STRUKTURAL/OPERASIONAL)
    v_kontrak_payung        → kontrak_payung + status_berlaku
    v_realisasi_revenue_tw  → SUM pencairan PARSIAL/FINAL per unit per TW
    v_realisasi_sales_tw    → SUM nilai_bersih proyek DEAL_KONTRAK per unit per TW
    v_posisi_kas            → saldo_awal + inflow - outflow

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API-01 — PROYEK (CRUD + Sub-Resources)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[CONTEXT di atas berlaku]

Buat modul modules/proyek/ yang berisi CRUD proyek lengkap beserta sub-resource-nya.
Dropdown proyek sudah ada di /api/v1/business/proyek/dropdown — jangan disentuh.

──────────────────────────────
ENDPOINT UTAMA PROYEK
──────────────────────────────
GET    /api/v1/proyek
  Query params: tahun, unitId, status, customerId, page, limit
  Filter Assistant Manager: hanya tampilkan unit_id milik unit sendiri
  Response item: { id, kodeProyek, namaProyek, customer:{id,nama},
    unit:{id,namaUnit,kodeUnit}, status, picSales:{id,nama}, pmo:{id,nama}?,
    nilaiBersih, tahun, updatedAt }

GET    /api/v1/proyek/{id}
  Response: semua field proyek + relasi kontrak + jumlahTeamMember + jumlahTagihan
  Field labelExisting pada customer (computed, tidak disimpan):
    true jika customer memiliki proyek lain berstatus DEAL_KONTRAK (selain proyek ini)

POST   /api/v1/proyek
  Role: Super Admin, Manager, Assistant Manager
  Body: { namaProyek, customerId, industriId, unitId, nilaiProyek, subkon?,
          picSalesId, pmoId?, departemen?, targetSelesai?,
          kontrakPayungId?, keterangan_pembayaran?, noKontrak?, tanggalKontrak? }
  Sistem generate kodeProyek: [prefix]-[kode_customer]-[tahun]
    prefix dari sys_config key='prefix_kode_proyek'
    kode_customer: 3-4 huruf dari nama customer (uppercase, ambil konsonan awal)
    tahun: EXTRACT(YEAR FROM CURRENT_DATE)
  status awal SELALU: 'INFO_PELUANG'
  tahun: EXTRACT(YEAR FROM CURRENT_DATE)
  Setelah INSERT proyek → INSERT log_status pertama dalam transaksi yang sama:
    status='INFO_PELUANG', tanggal=CURRENT_DATE, komentar='Proyek baru dibuat'

PUT    /api/v1/proyek/{id}
  Role: Super Admin, Manager, Assistant Manager (unit sendiri)
  Body: field yang boleh diubah (bukan status — status via log-status endpoint):
    namaProyek, nilaiProyek, subkon, picSalesId, pmoId, departemen,
    targetSelesai, kontrakPayungId, kontrakBiasaId, keterangan_pembayaran,
    noKontrak, tanggalKontrak, tanggalBast, tanggalMulai
  Audit: catat field yang berubah (sebelum vs sesudah)

──────────────────────────────
SUB-RESOURCE: LOG STATUS
──────────────────────────────
GET  /api/v1/proyek/{id}/log-status
  Response: list riwayat status, terbaru pertama
  Item: { id, status, komentar, tanggal, createdBy, createdAt }

POST /api/v1/proyek/{id}/log-status
  Role: Super Admin, Manager, Assistant Manager (unit sendiri)
  Body: { statusBaru, komentar, tanggal }

  BUSINESS RULES (WAJIB diimplementasikan persis):
  1. Validasi statusBaru ada di enum 7 nilai
  2. Ambil proyek.status saat ini — tolak 400 jika statusBaru == status saat ini
  3. Jika statusBaru == 'DEAL_KONTRAK':
       BEGIN TRANSACTION
         UPDATE proyek SET status='DEAL_KONTRAK', tanggal_deal=CURRENT_DATE,
                           updated_by=subjectId, updated_at=NOW()
         INSERT INTO log_status (proyek_id, status, komentar, tanggal, created_by)
       COMMIT
  4. Selain DEAL_KONTRAK:
       BEGIN TRANSACTION
         UPDATE proyek SET status=statusBaru, updated_by=subjectId
         INSERT INTO log_status
       COMMIT
  5. Audit: writeAudit('proyek', proyek.id, 'UPDATE', subject, ip,
             {sebelum:{status:statusLama}, sesudah:{status:statusBaru}})

──────────────────────────────
SUB-RESOURCE: UNIT SHARE
──────────────────────────────
GET    /api/v1/proyek/{id}/unit-share
POST   /api/v1/proyek/{id}/unit-share
  Body: { unitId, nilaiShare, persentase? }
PUT    /api/v1/proyek/{id}/unit-share/{shareId}
DELETE /api/v1/proyek/{id}/unit-share/{shareId}  → soft delete
Audit: writeAudit('unit_share', ...)

──────────────────────────────
SUB-RESOURCE: TEAM MEMBER
──────────────────────────────
GET    /api/v1/proyek/{id}/team-members
  Response item: { id, karyawan:{id,nik,nama,unitNama}, role:{id,namaRole},
    tglMulai, tglSelesai, bobot, keterangan, undanganStatus, undanganSentAt }

POST   /api/v1/proyek/{id}/team-members
  Role: Super Admin, Manager, Assistant Manager
  Body: { karyawanId, roleId, tglMulai?, tglSelesai?, bobot?, keterangan? }
  UNIQUE constraint (proyek_id, karyawan_id, tgl_mulai) → 409 jika duplikat
  Setelah INSERT:
    1. SET undangan_status='BELUM_DIKIRIM'
    2. Kirim email notifikasi via ballerina/email:
         To    : karyawan.email
         Subject: "Penugasan Proyek: [namaProyek]"
         Body  : nama karyawan, nama proyek, role, periode (tglMulai-tglSelesai)
         Ambil konfigurasi email dari sys_config (notif_team_member_aktif, notif_email_pengirim)
    3. Jika email berhasil → UPDATE undangan_status='TERKIRIM', undangan_sent_at=NOW()
       Jika gagal         → UPDATE undangan_status='GAGAL'
       INSERT notification: kategori='PENUGASAN', recipient=karyawanId,
         judul='Penugasan Proyek', pesan='Anda ditugaskan sebagai [role] pada [kodeProyek]',
         ref_table='proyek', ref_id=proyekId, link_label='Lihat Proyek'
  Audit: writeAudit('team_member', ...)

PUT    /api/v1/proyek/{id}/team-members/{tmId}
  Body: { roleId?, tglMulai?, tglSelesai?, bobot?, keterangan? }

DELETE /api/v1/proyek/{id}/team-members/{tmId}  → soft delete
  Audit: writeAudit('team_member', ...)

POST   /api/v1/proyek/{id}/team-members/{tmId}/kirim-undangan
  Kirim ulang email undangan untuk member yang undanganStatus != 'TERKIRIM'
  Update undangan_status sesuai hasil pengiriman

──────────────────────────────
SUB-RESOURCE: PROYEK TAGS
──────────────────────────────
GET    /api/v1/proyek/{id}/tags
POST   /api/v1/proyek/{id}/tags    Body: { tagId }
DELETE /api/v1/proyek/{id}/tags/{tagId}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API-02 — KONTRAK PAYUNG & KONTRAK BIASA
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[CONTEXT di atas berlaku]

Buat modul modules/kontrak/ (gabungkan kontrak_payung dan kontrak_biasa dalam satu modul).

──────────────────────────────
KONTRAK PAYUNG
──────────────────────────────
GET    /api/v1/kontrak-payung
  Query: customerId, statusBerlaku (BERLAKU|KEDALUWARSA), page, limit
  Gunakan v_kontrak_payung (bukan tabel langsung) agar status_berlaku sudah computed
  Response item: { id, noKontrakPayung, namaKontrak, customer:{id,nama},
    tanggalKontrak, tanggalMulai, tanggalSelesai, statusBerlaku, jumlahKontrakBiasa }

GET    /api/v1/kontrak-payung/{id}
  Response: detail + list harga_per_role + list kontrak_biasa turunan (ringkas)

POST   /api/v1/kontrak-payung
  Role: Super Admin, Manager
  Body: { customerId, noKontrakPayung, namaKontrak,
          tanggalKontrak, tanggalMulai, tanggalSelesai,   ← KETIGANYA WAJIB
          hargaPerRole: [{ roleId, tipeHarga, nilai, keterangan? }] }
  BEGIN TRANSACTION
    INSERT kontrak_payung
    INSERT INTO kontrak_payung_harga_role (batch, satu per item hargaPerRole)
  COMMIT
  Audit: writeAudit('kontrak_payung', ...)

PUT    /api/v1/kontrak-payung/{id}
  Body: { namaKontrak?, tanggalKontrak?, tanggalMulai?, tanggalSelesai? }
  Audit: writeAudit('kontrak_payung', ...)

DELETE /api/v1/kontrak-payung/{id}
  Cek dulu: tidak ada kontrak_biasa aktif (is_deleted=false) yang merujuk ini
  Jika ada → 409: "Kontrak Payung masih memiliki Kontrak Biasa aktif"
  Soft delete. Audit: writeAudit('kontrak_payung', ...)

──────────────────────────────
HARGA PER ROLE (sub-resource)
──────────────────────────────
GET    /api/v1/kontrak-payung/{id}/harga-role
POST   /api/v1/kontrak-payung/{id}/harga-role
  Body: { roleId, tipeHarga, nilai, keterangan? }
PUT    /api/v1/kontrak-payung/{id}/harga-role/{hrId}
DELETE /api/v1/kontrak-payung/{id}/harga-role/{hrId}  → hard delete (baris harga, bukan soft)

──────────────────────────────
KONTRAK BIASA
──────────────────────────────
GET    /api/v1/kontrak-biasa
  Query: kontrakPayungId, customerId, page, limit

GET    /api/v1/kontrak-biasa/{id}
  Response: detail + lookup harga dari kontrak_payung terkait (jika ada kontrakPayungId)

POST   /api/v1/kontrak-biasa
  Body: { kontrakPayungId?, customerId, noKontrakBiasa, namaKontrak,
          tanggalKontrak, nilai? }
  tanggalKontrak WAJIB (NOT NULL)
  Audit: writeAudit('kontrak_biasa', ...)

PUT    /api/v1/kontrak-biasa/{id}
DELETE /api/v1/kontrak-biasa/{id}
  Cek tidak ada proyek aktif yang merujuk → 409 jika ada
  Audit: writeAudit('kontrak_biasa', ...)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API-03 — TAGIHAN & PENCAIRAN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[CONTEXT di atas berlaku]

Buat modul modules/tagihan/.

──────────────────────────────
TAGIHAN
──────────────────────────────
GET    /api/v1/proyek/{proyekId}/tagihan
  Response item: { id, noTagihan, tanggalTagihan, nilaiTagihan, nilaiDpp, ppn, pph,
    statusAktif, totalCair, tanggalCairTerakhir, jumlahPencairan }
  totalCair dan tanggalCairTerakhir: computed dari pencairan_tagihan (JANGAN baca kolom lama)
    SELECT COALESCE(SUM(nilai),0), MAX(tanggal_pencairan)
    FROM pencairan_tagihan
    WHERE tagihan_id = t.id AND status IN ('PARSIAL','FINAL') AND is_deleted = false

GET    /api/v1/tagihan/{id}
  Response: semua field + list pencairan + list riwayat status

GET    /api/v1/revenue-unit
  Query: unitId, tahun, tw (1-4), status, customerId, page, limit
  Join: tagihan → proyek → unit (+ unit_share jika diperlukan split)
  Response item: { noTagihan, tanggalTagihan, mitra:customer.nama,
    project:{kode,nama}, tags:[], nilaiTagihan, statusAktif }

POST   /api/v1/proyek/{proyekId}/tagihan
  Role: Finance, Super Admin
  Body: { tanggalTagihan, nilaiTagihan, nilaiDpp?, ppn?, pph?, keterangan? }
  noTagihan generate: INV-[YYYY]-[sequence 3 digit per tahun]
  statusAktif default: 'RENCANA'
  Setelah INSERT → INSERT status_tagihan pertama (status='RENCANA', tanggal=today)
  Audit: writeAudit('tagihan', ...)

PUT    /api/v1/tagihan/{id}
  Body: { tanggalTagihan?, nilaiTagihan?, nilaiDpp?, ppn?, pph?, keterangan? }
  noTagihan IMMUTABLE (tidak bisa diubah)
  Audit: writeAudit('tagihan', ...)

DELETE /api/v1/tagihan/{id}
  Cek tidak ada pencairan PARSIAL/FINAL → 409 jika ada
  Soft delete. Audit: writeAudit('tagihan', ...)

──────────────────────────────
RIWAYAT STATUS TAGIHAN
──────────────────────────────
GET  /api/v1/tagihan/{id}/status-tagihan
POST /api/v1/tagihan/{id}/status-tagihan
  Body: { statusBaru, tanggal, keterangan? }
  UPDATE tagihan.status_aktif = statusBaru
  INSERT status_tagihan (dalam transaksi yang sama)

──────────────────────────────
PENCAIRAN TAGIHAN
──────────────────────────────
GET    /api/v1/tagihan/{tagihanId}/pencairan

POST   /api/v1/tagihan/{tagihanId}/pencairan
  Role: Finance, Super Admin
  Body: { tanggalPencairan, nilai, status, keterangan? }
  status enum: PARSIAL | FINAL | DIBATALKAN
  VALIDASI nilai > 0 → 400 jika tidak
  Audit: writeAudit('pencairan_tagihan', ...)

PUT    /api/v1/tagihan/{tagihanId}/pencairan/{id}
  HANYA boleh jika status == 'PARSIAL'
  Jika status == 'FINAL' → 400: "Pencairan Final tidak dapat diubah"
  Body: { tanggalPencairan?, nilai?, keterangan? }

DELETE /api/v1/tagihan/{tagihanId}/pencairan/{id}
  HANYA boleh jika status == 'PARSIAL'
  Jika status == 'FINAL' → 400: "Pencairan Final tidak dapat dihapus"
  Soft delete

NOTE PENTING:
  Realisasi Revenue → gunakan v_realisasi_revenue_tw (jangan hitung manual)
  Pencairan PARSIAL/FINAL bersifat final — tidak di-reverse meski tagihan → TIDAK_TERTAGIH

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API-04 — PEMBAYARAN & PENGELUARAN PERUSAHAAN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[CONTEXT di atas berlaku]

Buat modul modules/cashflow/ yang mencakup Pembayaran, Pengeluaran Perusahaan,
Saldo Awal Kas, dan Posisi Kas.

──────────────────────────────
KATEGORI FINANSIAL KELUAR
──────────────────────────────
GET    /api/v1/master/kategori-finansial           → list aktif (untuk dropdown)
POST   /api/v1/master/kategori-finansial           → tambah (Super Admin, Manager)
PUT    /api/v1/master/kategori-finansial/{id}
DELETE /api/v1/master/kategori-finansial/{id}      → soft delete

──────────────────────────────
PEMBAYARAN (terikat proyek)
──────────────────────────────
GET    /api/v1/pembayaran
  Query: status, proyekId, kategoriId, dari, sampai, page, limit

GET    /api/v1/pembayaran/{id}

POST   /api/v1/pembayaran
  Role: Manager, Assistant Manager, Finance, Super Admin
  Body: { proyekId, kategoriId, nilai, tanggalPengajuan, keterangan? }
  status awal: 'PENGAJUAN'
  Audit: writeAudit('pembayaran', ...)

PUT    /api/v1/pembayaran/{id}
  HANYA boleh jika status == 'PENGAJUAN' atau status == 'REJECTED'
  Body: { nilai?, kategoriId?, keterangan?, tanggalPengajuan? }
  Jika status == 'APPROVED' → 400: "Pembayaran yang sudah disetujui tidak dapat diubah"

POST   /api/v1/pembayaran/{id}/approve
  Body: { tanggalRealisasi? }
  VALIDASI APPROVER (CRITICAL — implementasikan persis):
    1. Ambil pembayaran.proyek_id → proyek.unit_id
    2. Ambil role user dari token
    3. Jika unit_id == 11 (Finance):
         Hanya Direktur atau Super Admin yang boleh approve
         Jika role bukan Direktur/Super Admin → 403
    4. Jika unit_id != 11:
         Hanya Finance atau Super Admin yang boleh approve
         Jika role bukan Finance/Super Admin → 403
  UPDATE status='APPROVED', approved_by=subjectId, approved_at=NOW(),
         tanggal_realisasi=tanggalRealisasi (null jika tidak dikirim)
  Audit: writeAudit('pembayaran', ..., {sebelum:{status:'PENGAJUAN'}, sesudah:{status:'APPROVED'}})

POST   /api/v1/pembayaran/{id}/reject
  Body: { catatanPenolakan }  ← WAJIB, min 5 karakter
  VALIDASI APPROVER: sama seperti approve
  UPDATE status='REJECTED', catatan_approval=catatanPenolakan

POST   /api/v1/pembayaran/{id}/revisi
  HANYA boleh jika status == 'REJECTED'
  Body: { nilai?, kategoriId?, keterangan? }  ← optional, update sekalian jika ada
  UPDATE status='PENGAJUAN' (+ update field lain jika ada di body)
  Audit: writeAudit('pembayaran', ..., {revisi dari REJECTED ke PENGAJUAN})

POST   /api/v1/pembayaran/{id}/realisasi
  Body: { tanggalRealisasi }
  HANYA boleh jika status == 'APPROVED' dan tanggal_realisasi belum terisi
  UPDATE tanggal_realisasi = tanggalRealisasi
  ⚠️ Ini yang menyebabkan pembayaran ini dihitung sebagai cash-out di v_posisi_kas

──────────────────────────────
PENGELUARAN PERUSAHAAN (tidak terikat proyek)
──────────────────────────────
Endpoint identik dengan Pembayaran, path: /api/v1/pengeluaran
Perbedaan: body pakai { unitId, ... } bukan { proyekId, ... }
VALIDASI APPROVER:
  Ganti langkah "ambil proyek.unit_id" dengan unit_id langsung dari pengeluaran.unit_id
  Aturan sama: jika unitId==11 → approver Direktur/Super Admin; selainnya → Finance/Super Admin

──────────────────────────────
SALDO AWAL KAS
──────────────────────────────
GET  /api/v1/saldo-kas
  Response: list histori saldo, terbaru pertama
  Item: { id, tanggal, nilai, keterangan, createdBy, createdAt }

POST /api/v1/saldo-kas
  Role: Finance, Super Admin
  Body: { tanggal, nilai, keterangan? }
  APPEND-ONLY: tidak ada endpoint PUT, PATCH, DELETE untuk ini
  Audit: writeAudit('saldo_awal_kas', ...)

──────────────────────────────
POSISI KAS & CHART CASHFLOW
──────────────────────────────
GET /api/v1/posisi-kas
  Query dari v_posisi_kas (jangan hitung manual)
  Response: { tanggalSaldoAwal, saldoAwal, totalInflow, totalOutflow, posisiKas }

GET /api/v1/cashflow/chart
  Query: tahun (required)
  Hitung per bulan (Januari s.d. bulan saat ini atau bulan 12 jika tahun lalu):
    inflow  : SUM(pencairan_tagihan.nilai) WHERE status IN ('PARSIAL','FINAL')
              AND tanggal_pencairan BETWEEN awal_bulan AND akhir_bulan
    outflow : SUM(pembayaran.nilai + pengeluaran_perusahaan.nilai)
              WHERE status='APPROVED' AND tanggal_realisasi BETWEEN awal_bulan AND akhir_bulan
  Response: {
    summary: { totalInflow, totalOutflow, netCashflow, posisiKas },
    bulanByBulan: [{ bulan:"2026-01", inflow, outflow, netCashflow }]
  }

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API-05 — TARGET & LAPORAN SALES/REVENUE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[CONTEXT di atas berlaku]

Buat modul modules/target/ dan modules/laporan/.

──────────────────────────────
JABATAN MASTER (belum ada endpoint)
──────────────────────────────
GET  /api/v1/master/jabatan             → list (filter: kategori)
POST /api/v1/master/jabatan             → tambah (Super Admin saja)
PUT  /api/v1/master/jabatan/{id}
DELETE /api/v1/master/jabatan/{id}      → soft delete

──────────────────────────────
PROJECT ROLE MASTER (belum ada endpoint)
──────────────────────────────
GET    /api/v1/master/project-roles     → list aktif (untuk dropdown Team Member & Harga Kontrak)
POST   /api/v1/master/project-roles     → Super Admin saja
PUT    /api/v1/master/project-roles/{id}
DELETE /api/v1/master/project-roles/{id}
  Cek tidak dipakai team_member aktif → 409 jika ada

──────────────────────────────
RESOURCE UNIT (CRUD — bukan dropdown)
──────────────────────────────
GET    /api/v1/resource-unit            → list semua resource unit
GET    /api/v1/resource-unit/{id}       → detail
POST   /api/v1/resource-unit            → tambah
  Body: { unitId, leadId?, jumlah, kapasitasTerpakai, status }
  UNIQUE (unit_id) → 409 jika unit sudah punya resource unit
PUT    /api/v1/resource-unit/{id}
DELETE /api/v1/resource-unit/{id}       → soft delete

──────────────────────────────
TARGET SALES UNIT
──────────────────────────────
GET  /api/v1/target-sales
  Query: tahun, unitId, page, limit
  Response item: { id, unit:{id,namaUnit,kodeUnit}, tahun,
    targetTw1..4, totalTarget, realisasiTw1..4 (dari v_realisasi_sales_tw) }

GET  /api/v1/target-sales/{unitId}/{tahun}

POST /api/v1/target-sales
  Role: Manager, Super Admin
  Body: { unitId, tahun, targetTw1, targetTw2, targetTw3, targetTw4 }
  VALIDASI unit bersifat OPERASIONAL (cek via v_unit.tipe_unit) → 400 jika STRUKTURAL
  UNIQUE (unitId, tahun) → 409 jika sudah ada

PUT  /api/v1/target-sales/{id}
  Body: { targetTw1?, targetTw2?, targetTw3?, targetTw4? }

──────────────────────────────
TARGET REVENUE UNIT
──────────────────────────────
Endpoint identik dengan target-sales, path: /api/v1/target-revenue
Role untuk POST/PUT: Finance, Super Admin

──────────────────────────────
LAPORAN: PENCAPAIAN SALES
──────────────────────────────
GET /api/v1/pencapaian-sales
  Query: tahun (required), unitId (optional)
  Gabung target_sales_unit + v_realisasi_sales_tw (deal-basis)
  Response per unit: {
    unitId, namaUnit, kodeUnit,
    targetTw1..4, totalTarget,
    realisasiTw1..4, totalRealisasi,
    persenTw1..4, persenTotal
  }
  NOTE: SES tidak muncul (STRUKTURAL). Tampilkan SD dan SE terpisah.
  Role: semua (Asst. Manager hanya unit sendiri)
  Export CSV: GET + query param format=csv → 403 untuk Asst. Manager

──────────────────────────────
LAPORAN: SALES MATRIX
──────────────────────────────
GET /api/v1/sales-matrix
  Query: tahun (required), mode (per_unit|per_triwulan, default: per_unit)
  Sama dengan pencapaian-sales tapi dalam format matrix
  per_unit:      rows=unit, columns=TW1..4+total
  per_triwulan:  rows=TW, columns=unit
  Tambahkan baris total (sum semua unit)

──────────────────────────────
LAPORAN: REVENUE UNIT PER TW
──────────────────────────────
GET /api/v1/revenue-unit/per-tw
  Query: tahun (required), unitId (optional)
  Join: proyek → tagihan, gunakan v_realisasi_revenue_tw
  Response: { unit, proyek, customer, nilaiKontrak, pencairanPerTW, piutang }

──────────────────────────────
LAPORAN: CHART REVENUE UNIT
──────────────────────────────
GET /api/v1/chart-revenue
  Query: tahun (required)
  Response per unit: {
    unitId, namaUnit, target,
    tagihan_lunas: SUM nilaiTagihan WHERE status_aktif='LUNAS',
    piutang: SUM nilaiTagihan WHERE status_aktif IN ('BAST','KIRIM_TAGIHAN'),
    peluang: SUM nilaiTagihan WHERE status_aktif IN ('PELUANG','RENCANA'),
    targetSisa: target - (tagihan_lunas + piutang + peluang)
  }
  Hanya unit OPERASIONAL. SES tidak muncul.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API-06 — NOTIFIKASI & AUDIT LOG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[CONTEXT di atas berlaku]

Buat modul modules/notifikasi/ dan modules/audit/.

──────────────────────────────
NOTIFIKASI
──────────────────────────────
GET  /api/v1/notifikasi
  Filter: kategori (PENUGASAN|STATUS|SISTEM|semua), isRead (true|false), page, limit
  ⚠️ Hanya tampilkan notifikasi milik user yang login:
     Ambil subjectId dari token → cari karyawan.id WHERE subject_id = subjectId
     Filter: recipient_karyawan_id = karyawan_id tersebut

GET  /api/v1/notifikasi/unread-count
  Response: { count: int }

GET  /api/v1/notifikasi/{id}

PUT  /api/v1/notifikasi/{id}/read
  UPDATE is_read=true, read_at=NOW()

PUT  /api/v1/notifikasi/read-all
  UPDATE is_read=true, read_at=NOW() WHERE recipient_karyawan_id = karyawan_id dan is_read=false

HELPER (gunakan di modul lain yang memicu notifikasi):
  function createNotification(
      dbClient, recipientKaryawanId, kategori, judul, pesan,
      refTable?, refId?, linkLabel?
  ) returns error? {
      // INSERT notification
      // Jika gagal: log error, JANGAN propagate ke caller
  }
  Taruh di utils.bal atau notifikasi_service.bal agar bisa di-import semua modul.

──────────────────────────────
EMAIL LOG
──────────────────────────────
Tidak ada endpoint publik untuk email log.
Update notification_email_log dilakukan internal saat kirim email di team member.

──────────────────────────────
AUDIT LOG
──────────────────────────────
GET /api/v1/audit-log
  Role: Super Admin, Direktur (403 untuk role lain)
  Query: tableName, aksi (CREATE|UPDATE|DELETE), aktor, dari, sampai, page, limit
  Default sort: waktu DESC
  Response item: { id, tableName, recordId, aksi, aktorSubjectId,
    aktorNama (JOIN user_cache), ipAddress, ringkasanPerubahan, waktu }

GET /api/v1/audit-log/{id}
  Response: item lengkap + perubahan (JSON parsed: {sebelum:{}, sesudah:{}})

GET /api/v1/audit-log/export
  Role check: Finance, Manager, Direktur, Super Admin (403 untuk Asst. Manager)
  Query param: format=csv (default)
  Return: CSV dengan header: Waktu,Modul,Record ID,Aksi,Aktor,IP,Perubahan
  Content-Type: text/csv; charset=utf-8
  Content-Disposition: attachment; filename="audit-log-[tanggal].csv"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API-07 — MANAJEMEN USER, SINKRONISASI IS & KONFIGURASI SISTEM
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[CONTEXT di atas berlaku]

Buat modul modules/user_mgmt/ dan modules/pengaturan/.

──────────────────────────────
MANAJEMEN USER (SCIM2 PROXY)
──────────────────────────────
Semua endpoint di bawah ini memanggil IS menggunakan APP-LEVEL credential
(bukan token user yang login). Ballerina sebagai proxy tipis.
Role: HANYA Super Admin boleh akses.

Konfigurasi IS client:
  configurable string isBaseUrl       = ?;   // https://iam.apicentrum.biz.id
  configurable string isClientId      = ?;
  configurable string isClientSecret  = ?;
  // Panggil IS dengan HTTP Basic Auth: isClientId:isClientSecret

GET    /api/v1/users
  Panggil IS: GET /scim2/Users?startIndex=1&count=20
  Map response IS ke ApiResponse standar
  Response item: { id, username, namaLengkap, email, roles:[], statusAktif }

GET    /api/v1/users/{id}
  Panggil IS: GET /scim2/Users/{id}

POST   /api/v1/users
  Body: { username, password, namaLengkap, email, roleId }
  Panggil IS: POST /scim2/Users
  Setelah berhasil: assign role via PATCH /scim2/Groups/{roleId}
    body: { Operations: [{ op:"add", path:"members", value:[{value: newUserId}] }] }
  Catat: writeAudit('ManajemenUser', newUserId, 'CREATE', subjectId, ip, {username, email})

PUT    /api/v1/users/{id}
  Body: { namaLengkap?, email?, roleId? }
  Panggil IS: PUT /scim2/Users/{id}
  Jika roleId berubah: PATCH /scim2/Groups untuk remove dari role lama + add ke role baru
  Catat: writeAudit('ManajemenUser', id, 'UPDATE', ...)

POST   /api/v1/users/{id}/toggle-status
  Body: { aktif: boolean }
  Panggil IS: PATCH /scim2/Users/{id}
    body: { Operations: [{ op:"replace", path:"active", value: aktif }] }
  Catat: writeAudit('ManajemenUser', id, 'UPDATE', ...)

GET    /api/v1/roles
  Panggil IS: GET /scim2/Groups
  Response: list group/role dari IS

──────────────────────────────
SINKRONISASI IS (Reconciliation)
──────────────────────────────
POST /api/v1/sync/trigger
  Role: Super Admin
  Jalankan proses sync segera (bukan scheduled):
    1. Panggil IS: GET /scim2/Users (paginasi, ambil semua)
    2. Untuk setiap user: UPSERT user_cache
         (subject_id, nama, email, status, last_synced_at=NOW())
    3. UPDATE sys_config: last_sync_at=NOW(), last_sync_status='BERHASIL' atau 'GAGAL'
  Response: { synced: int, updated: int, failed: int, duration_ms: int }

Scheduled job (ballerina/task):
  Jalankan fungsi sync yang sama di atas, terjadwal sesuai sys_config.jadwal_reconciliation
  Default: setiap hari pukul 02:00
  Jika gagal: UPDATE sys_config.last_sync_status='GAGAL', log error

──────────────────────────────
KONFIGURASI SISTEM (sys_config)
──────────────────────────────
GET /api/v1/pengaturan
  Role: Super Admin (untuk seluruh config); role lain hanya baca config non-sensitif
  Response: list key-value dari sys_config
  Field sensitif (isClientId, isClientSecret dll) → JANGAN masukkan ke response publik
    Hanya kembalikan 12 key yang didefinisikan di PRD:
    prefix_kode_proyek, prefix_nomor_surat, format_tanggal, format_mata_uang,
    notif_team_member_aktif, notif_max_kirim_menit, notif_email_pengirim,
    scim2_url, jadwal_reconciliation, last_sync_at, last_sync_status, nama_aplikasi

PUT /api/v1/pengaturan
  Role: Super Admin saja
  Body: { key: value, ... }  ← update satu atau lebih key sekaligus
  WHITELIST key yang boleh diupdate:
    prefix_kode_proyek, prefix_nomor_surat, format_tanggal, format_mata_uang,
    notif_team_member_aktif, notif_max_kirim_menit, notif_email_pengirim,
    scim2_url, jadwal_reconciliation
  READ-ONLY (tolak 400 jika ada di body):
    last_sync_at, last_sync_status, nama_aplikasi

POST /api/v1/pengaturan/sync
  Role: Super Admin
  Alias untuk /api/v1/sync/trigger (panggil fungsi yang sama)

GET /api/v1/pengaturan/sys-info
  Response: { namaAplikasi (dari sys_config), versi (dari env APP_VERSION),
              environment (dari env APP_ENV) }
  Tidak ada role restriction — semua role boleh akses