# PROMPT CLAUDE DESIGN

# Swamedia Project Website Portal — UI Redesign v2.0

# Gunakan prompt ini di Claude Design untuk menghasilkan desain halaman per halaman.

# Setiap blok [HALAMAN XX] adalah prompt terpisah untuk satu layar.

# Selalu sertakan KONTEKS UMUM di bawah ini sebelum menjalankan prompt halaman manapun.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
KONTEKS UMUM (SERTAKAN DI SETIAP PROMPT)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Nama aplikasi: Swamedia Project Website Portal
Perusahaan: PT Swamedia Informatika
Jenis: Internal business management portal (bukan produk publik)
Stack: Next.js (frontend) · Ballerina (backend) · WSO2 APIM · WSO2 Identity Server · PostgreSQL

DESIGN SYSTEM:

- Font: Inter (system-ui fallback), angka numerik pakai font-variant-numeric: tabular-nums
- Primary navy: #1E3A5F
- Sidebar dark: #162D4A
- Accent blue: #2563EB
- Success: #16A34A · Warning: #D97706 · Danger: #DC2626
- Background: #F1F5F9 · Card: #FFFFFF · Border: #E2E8F0
- Text primary: #0F172A · Text secondary: #475569 · Text muted: #94A3B8
- Border radius: card=10px, button=7px, badge=20px, avatar=50%
- Shadow card: 0 1px 3px rgba(0,0,0,0.08)

LAYOUT TETAP (semua halaman):

- Sidebar kiri lebar 232px, background #162D4A, fixed
- Topbar atas tinggi 52px, background putih, border-bottom #E2E8F0
- Content area: background #F1F5F9, padding 24px, scrollable
- Footer sidebar: avatar + nama + role badge + ikon logout
- Topbar kanan: ikon notifikasi (dengan badge merah angka unread) + avatar user + nama + role dropdown

SIDEBAR NAVIGATION (urutan tetap):
MENU UTAMA: Dashboard · Karyawan
SALES & MARKETING: Sales Unit (Proyek) · Revenue Unit · Chart Revenue Unit · Chart Cashflow · Customer · Contact · Industri · Kontrak Payung · Target Sales Unit · Sales Matrix · Pencapaian Sales Unit · Target Revenue Unit · Revenue Unit per TW · Pembayaran · Pengeluaran Perusahaan · Nomor Surat [sub: Daftar Surat, Kategori Surat] · Resource Tags · Resource Unit
ADMIN: Unit (Organisasi)
SISTEM: Audit Log
PENGATURAN: Profil Saya · Notifikasi · Manajemen User · Role & Permission · Konfigurasi Sistem

5 RBAC ROLE (gunakan salah satu sesuai demo halaman):
Super Admin · Direktur · Manager · Assistant Manager · Finance

STATUS PROYEK (enum, gunakan label ini, bukan label bebas):
Info Peluang · Undangan Penjelasan · Meeting Inisiasi · Proses Proposal · Evaluasi Admin/Teknis · Deal/Kontrak · Gagal

STATUS BADGE COLOR:
Deal/Kontrak → hijau (#F0FDF4 bg, #15803D text)
Proses Proposal / Meeting Inisiasi → oranye (#FFF7ED bg, #C2410C text)
Evaluasi Admin/Teknis → amber (#FFFBEB bg, #B45309 text)
Info Peluang / Undangan Penjelasan → biru (#EFF6FF bg, #1D4ED8 text)
Gagal → merah (#FEF2F2 bg, #B91C1C text)

CUSTOMER JENIS: Enterprise · Banking · BUMN · Government
CUSTOMER STATUS PELUANG: Prospek · Negosiasi · Deal · Batal

PROJECT ROLE (15 nilai): Backend Developer · Frontend Developer · Mobile Developer · Middleware Developer · Senior Middleware Developer · Database Developer · Software Tester · System Analyst · IT Operation and Maintenance · IT Support · Technical Support · Technical Writer · UI/UX Designer · Project Coordinator · Project Manager Officer

UNIT ORGANISASI (13 unit, gunakan kode ini):
DIRUT (Direktur Utama) → BDGA (Dir. BD & GA) → MKT (Marketing & Sales)
DIRUT → EBISHC (Dir. EBIS & HC) → PMO · DES · BILL · SES → SD (Service Delivery) · SE (Strategic Enablement) · POS · HC
DIRUT → FIN (Finance)

PENCAIRAN STATUS: Parsial · Final · Dibatalkan
PEMBAYARAN/PENGELUARAN STATUS: Pengajuan · Approved · Rejected

ATURAN APPROVAL CASHFLOW:

- Finance menyetujui semua pengajuan Pembayaran & Pengeluaran Perusahaan
- KECUALI: pengajuan dari unit Finance sendiri → disetujui Direktur Utama

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 01 — DASHBOARD
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Dashboard untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

LAYOUT HALAMAN (dari atas ke bawah):

1. KPI CARDS (4 kolom sejajar):
   - Total Proyek Aktif: 24 (+3 dari bulan lalu) — ikon folder, accent biru
   - Revenue Bulan Ini: Rp 6,1 M (+12% vs bulan lalu) — ikon bar chart, accent hijau
   - Target Sales Sisa: Rp 8,85 M (26% dari total target) — ikon clock, accent amber
   - Posisi Kas: Rp 12,8 M (Surplus — kondisi aman) — ikon kartu kredit, accent biru

2. BARIS KEDUA (2 kolom, rasio 60/40):
   Kolom kiri — Card "Tren Revenue":
   - Subjudul: "Realisasi pencairan 6 bulan terakhir"
   - Badge kanan header: "+12% YoY" (hijau)
   - Bar chart 6 bulan: Jan 3,2M · Feb 4,1M · Mar 3,8M · Apr 5,2M · Mei 4,7M · Jun 6,1M
   - Bar bulan Juni berwarna navy gelap (#1E3A5F), bulan lain biru accent (#2563EB)
   - Di bawah chart, ringkasan: "Total H1 2026: Rp 27,1 M · Avg/bulan: Rp 4,5 M"
   - Di bawah ringkasan, garis pemisah, lalu strip TW Target Revenue 2026:
     Label "Pencapaian Target Revenue per Triwulan — 2026"
     TW1: progress bar 103% (hijau, gradient #16A34A→#4ADE80)
     TW2: progress bar 74% (amber, gradient #D97706→#FBBF24)
     TW3: progress bar abu (belum berjalan)
     TW4: progress bar abu (belum berjalan)
     Catatan kecil: "TW1 selesai ✔ · TW2 berjalan (s.d. Jun 2026) · TW3–TW4 belum dimulai"

   Kolom kanan — Card "Aktivitas Terbaru":
   - Subjudul: "Log perubahan proyek & keuangan"
   - Link kanan: "Semua →"
   - Feed 6 item (avatar bulat + teks + meta waktu):
     AP (biru) — Andi Pratama mengubah status PRJ-TELKOM-2026 menjadi Deal/Kontrak · 2 jam lalu
     RW (hijau) — Rina Wijaya menambahkan pencairan INV-2026-031 pada PRJ-BNI-2026 · 5 jam lalu
     DS (ungu) — Dimas Saputra memperbarui unit share PRJ-PLN-2026 · Kemarin, 18:20
     SA (amber) — Sari Anggraini membuat proyek baru PRJ-WIKA-2026 · Kemarin, 09:05
     BS (teal) — Budi Santoso menambah anggota tim pada PRJ-MANDIRI-2026 · 2 hari lalu
     FH (merah) — Finance HC menyetujui pembayaran PAY-2026-018 — Rp 45 jt · 2 hari lalu

3. BARIS KETIGA (2 kolom, rasio 60/40):
   Kolom kiri — Card "Proyek Terbaru":
   - Link kanan header: "Lihat semua →"
   - Tabel 5 proyek: kolom Kode Proyek (biru, bold) · Customer · Status (badge warna) · PIC (avatar+nama) · Nilai Bersih (rata kanan, bold)
   - Data:
     PRJ-TELKOM-2026 | PT Telkom Indonesia | Deal/Kontrak | AP Andi Pratama | Rp 4.250.000.000
     PRJ-MANDIRI-2026 | PT Bank Mandiri | Deal/Kontrak | DS Dimas Saputra | Rp 5.600.000.000
     PRJ-PLN-2026 | PT PLN (Persero) | Evaluasi Admin/Teknis | DS Dimas Saputra | Rp 6.120.000.000
     PRJ-BRI-2026 | PT Bank BRI | Proses Proposal | RW Rina Wijaya | Rp 2.800.000.000
     PRJ-KAI-2026 | PT Kereta Api Indonesia | Proses Proposal | SA Sari Anggraini | Rp 2.150.000.000
   - Row hover: background #F1F5F9

   Kolom kanan (stack vertikal):
   Card atas — "Cashflow YTD" (Jan–Jun 2026):
   - 2 stat dalam grid 2 kolom: Total Inflow Rp 22,4 M (hijau) · Total Outflow Rp 15,2 M (merah)
   - Di bawah: "Posisi Kas Saat Ini" Rp 12,8 M besar, subjudul "Surplus Rp 7,2 M · Kondisi aman"
   - Progress bar horizontal: fill 68% (gradient biru), label "Outflow 68%"

   Card bawah — "Menunggu Persetujuan" (badge amber "3"):
   - Daftar 3 item: dot amber + nama pengajuan + tipe + tanggal + nilai
     Subkon DBA — PRJ-PLN-2026 · Pembayaran · 2 hari lalu · Rp 45 Jt
     Operasional Kantor Q3 · Pengeluaran Perusahaan · 3 hari lalu · Rp 12 Jt
     Lisensi Software — DES Unit · Pengeluaran Perusahaan · 4 hari lalu · Rp 8 Jt

USER DEMO: Citra Lestari · Role: Manager · Avatar inisial "CL" biru

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 02 — SALES UNIT / PROYEK (TABEL)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman daftar Sales Unit (Proyek) dalam tampilan Tabel untuk Swamedia Project Website Portal.
Tidak ada tampilan Kanban — hanya tampilan tabel.

[KONTEKS UMUM di atas berlaku]

HEADER HALAMAN:

- Breadcrumb: Sales & Marketing / Sales Unit (Proyek)
- Judul: "Sales Unit (Proyek)"
- Tombol "+ Tambah Proyek" (biru, kanan atas)

FILTER BAR (satu baris, di bawah judul):
Tahun: [2026 ▾] · Unit: [Semua ▾] · Status: [Semua ▾] · Customer: [Semua ▾] · [Search kode/nama proyek]

TABEL (8 baris data):
Kolom: Kode Proyek · Nama Proyek · Customer · Unit · Status · PIC Sales · Nilai Bersih · Tgl Update · Aksi

PRJ-TELKOM-2026 | Enterprise API Integration | PT Telkom Indonesia | DES | Deal/Kontrak (hijau) | AP Andi Pratama | Rp 4.250.000.000 | 10 Jul 2026 | [Lihat][Edit][Hapus]
PRJ-MANDIRI-2026 | Core Banking Modernization | PT Bank Mandiri | BILL | Deal/Kontrak (hijau) | DS Dimas Saputra | Rp 5.600.000.000 | 09 Jul 2026 | [Lihat][Edit][Hapus]
PRJ-PLN-2026 | SCADA System Integration | PT PLN (Persero) | DES | Evaluasi Admin/Teknis (amber) | DS Dimas Saputra | Rp 6.120.000.000 | 07 Jul 2026 | [Lihat][Edit][Hapus]
PRJ-BRI-2026 | Digital Channel Enhancement | PT Bank BRI | BILL | Proses Proposal (oranye) | RW Rina Wijaya | Rp 2.800.000.000 | 05 Jul 2026 | [Lihat][Edit][Hapus]
PRJ-KAI-2026 | Ticketing System Overhaul | PT Kereta Api Indonesia | POS | Proses Proposal (oranye) | SA Sari Anggraini | Rp 2.150.000.000 | 04 Jul 2026 | [Lihat][Edit][Hapus]
PRJ-PERTAMINA-2026 | ERP Phase 2 | PT Pertamina | SD | Meeting Inisiasi (oranye) | AP Andi Pratama | Rp 3.500.000.000 | 02 Jul 2026 | [Lihat][Edit][Hapus]
PRJ-GARUDA-2026 | HR System Migration | PT Garuda Indonesia | HC | Info Peluang (biru) | RW Rina Wijaya | Rp 1.800.000.000 | 30 Jun 2026 | [Lihat][Edit][Hapus]
PRJ-XYZ-2025 | Data Warehouse | PT XYZ Tbk | SE | Gagal (merah, teks redup) | BS Budi Santoso | Rp 900.000.000 | 15 Mar 2025 | [Lihat]

BARIS TOTAL di footer tabel: "Total 8 proyek · Nilai Bersih Total: Rp 27.120.000.000"

PAGINATION: Menampilkan 1–8 dari 24 proyek · [< Prev] [1] [2] [3] [Next >]

KOLOM UNIT: tampilkan sebagai chip/tag kecil dengan kode singkat (DES, BILL, POS, dst.) — background abu terang
BARIS PROYEK GAGAL: teks lebih redup (opacity 60%), baris tidak bisa diedit (hanya [Lihat])
ROW HOVER: background #F1F5F9

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 03 — DETAIL PROYEK
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Detail Proyek untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

BREADCRUMB: Sales Unit (Proyek) / PRJ-TELKOM-2026

HEADER PROYEK (card besar di atas):

- Kiri: Kode "PRJ-TELKOM-2026" (bold, 18px) + badge "Deal/Kontrak" hijau
- Nama proyek: "Enterprise API Integration — PT Telkom Indonesia" (20px bold)
- Meta row: Unit: DES · Customer: PT Telkom Indonesia · Tahun: 2026 · PIC Sales: Andi Pratama · PMO: Budi Santoso
- Kanan: Nilai Proyek Rp 5.000.000.000 · Subkon Rp 750.000.000 · Nilai Bersih Rp 4.250.000.000 (hijau bold)
- Tombol: [Edit Proyek] [Update Status]

TAB NAVIGATION (dibawah header, horizontal):
[Log Status] [Unit Share] [Team Members] [Tagihan] [Pencairan] [Tags]

TAB AKTIF: Log Status

- Tombol "+ Update Status" kanan atas (kecil, biru)
- Timeline vertikal dari atas (terbaru) ke bawah (terlama):
  ● Deal/Kontrak — 10 Jul 2026 — Andi Pratama
  "Kontrak ditandatangani, PO diterima dari Telkom"
  ● Evaluasi Admin/Teknis — 25 Jun 2026 — Andi Pratama
  "Dokumen teknis disetujui procurement Telkom"
  ● Proses Proposal — 05 Jun 2026 — Andi Pratama
  "BoQ dan proposal teknis dikirimkan ke client"
  ● Meeting Inisiasi — 20 Mei 2026 — Andi Pratama
  "Kick-off meeting dengan tim Telkom Enterprise"
  ● Info Peluang — 01 Mei 2026 — Andi Pratama
  "Dapat info tender dari kontak internal Telkom"
- Timeline marker: bulat berwarna sesuai status, garis vertikal penghubung

SIDEBAR KANAN (sticky, lebar 280px):

- Card "Kontrak Payung": KP-TSEL-2025 · Berlaku s.d. 31 Des 2026 · badge hijau "Berlaku"
- Card "Keterangan Pembayaran": termin 30-40-30, net 30 hari
- Card "Aktivitas": 3 aktivitas terbaru pada proyek ini

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 04 — DETAIL PROYEK — TAB TEAM MEMBERS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat tab Team Members pada halaman Detail Proyek.

[KONTEKS UMUM di atas berlaku]
[Sama seperti Halaman 03, tab "Team Members" yang aktif]

KONTEN TAB:

- Tombol "+ Tambah Anggota" kanan atas (kecil, biru)
- Tabel dengan kolom: Karyawan · Project Role · Periode · Bobot · Status Undangan · Aksi

DATA (6 baris):
Andi Pratama | Project Manager Officer | 01 Mei — 31 Des 2026 | 20% | Terkirim (hijau) | [Edit][Hapus]
Dimas Saputra | System Analyst | 01 Mei — 31 Des 2026 | 30% | Terkirim (hijau) | [Edit][Hapus]
Rina Wijaya | Backend Developer | 01 Jun — 31 Des 2026 | 40% | Terkirim (hijau) | [Edit][Hapus]
Budi Santoso | Database Developer | 15 Jun — 30 Sep 2026 | 30% | Terkirim (hijau) | [Edit][Hapus]
Sari Anggraini | Frontend Developer | 01 Jul — 31 Des 2026 | 35% | Belum Dikirim (abu) | [Edit][Kirim Ulang][Hapus]
Ahmad Fauzi | Software Tester | 01 Ags — 30 Nov 2026 | 25% | Belum Dikirim (abu) | [Edit][Kirim Ulang][Hapus]

STATUS UNDANGAN BADGE:

- Terkirim: background hijau muda, teks hijau
- Belum Dikirim: background abu, teks abu
- Gagal: background merah muda, teks merah — dengan tombol "Kirim Ulang"

INFO BOX (di atas tabel, warna biru terang):
"Email notifikasi penugasan dikirim otomatis saat anggota ditambahkan. Tombol Kirim Ulang tersedia untuk status Belum Dikirim atau Gagal."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 05 — DETAIL PROYEK — TAB TAGIHAN & PENCAIRAN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat tab Tagihan & Pencairan pada halaman Detail Proyek.

[KONTEKS UMUM di atas berlaku]
[Sama seperti Halaman 03, tab "Tagihan" yang aktif]

KONTEN TAB — dua section:

SECTION 1: TAGIHAN

- Tombol "+ Tambah Tagihan" kanan atas
- Tabel tagihan dengan expand per baris:
  Kolom: No. Tagihan · Tanggal · Nilai · DPP · PPN · PPh · Status · Total Cair · Aksi

DATA 3 TAGIHAN (baris expandable):
▼ INV-2026-001 | 15 Apr 2026 | Rp 1.250.000.000 | DPP 1.136.363.636 | PPN 125.000.000 | PPh 25.000.000 | KIRIM TAGIHAN (amber) | Cair: Rp 750.000.000 | [Detail][Edit]
▼ INV-2026-014 | 30 Mei 2026 | Rp 1.500.000.000 | DPP 1.363.636.363 | PPN 150.000.000 | PPh 30.000.000 | RENCANA (abu) | Cair: Rp 0 | [Detail][Edit]
▼ INV-2026-027 | 10 Jul 2026 | Rp 1.500.000.000 | DPP 1.363.636.363 | PPN 150.000.000 | PPh 30.000.000 | RENCANA (abu) | Cair: Rp 0 | [Detail][Edit]

SECTION 2: PENCAIRAN (saat tagihan INV-2026-001 di-expand)

- Sub-tabel di bawah baris tagihan INV-2026-001:
  Kolom: Tanggal Pencairan · Nilai · Status · Keterangan · Aksi
  15 Mei 2026 | Rp 750.000.000 | Parsial (amber) | DP 50% diterima | [Edit]
  Tombol "+ Tambah Pencairan" di bawah sub-tabel

STATUS TAGIHAN BADGE: Lunas=hijau · Kirim Tagihan=amber · BAST=biru · Rencana=abu · Peluang=ungu · Tidak Tertagih=merah
STATUS PENCAIRAN BADGE: Final=hijau · Parsial=amber · Dibatalkan=merah

INFO NOTE (kecil, italic, abu):
"Nilai yang sudah cair berstatus Parsial/Final tidak dapat di-reverse. Perubahan status tagihan menjadi Tidak Tertagih tidak membatalkan pencairan yang sudah tercatat."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 06 — CUSTOMER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman daftar Customer untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Customer" · "+ Tambah Data" kanan atas

FILTER BAR: Search (nama customer) · Jenis Customer (dropdown: Semua/Enterprise/Banking/BUMN/Government) · Status Peluang (dropdown)

TABEL (7 baris data):
Kolom: No · Nama Customer · Account Manager · Status Peluang · Jenis · Label Existing · Aksi

PT Telkom Indonesia | Andi Pratama | Deal (hijau) | Enterprise | Existing (badge navy) | [Edit][Hapus]
PT Bank Mandiri | Dimas Saputra | Deal (hijau) | Banking | Existing (badge navy) | [Edit][Hapus]
PT PLN (Persero) | Dimas Saputra | Negosiasi (amber) | BUMN | Existing (badge navy) | [Edit][Hapus]
PT Bank BRI | Andi Pratama | Prospek (biru) | Banking | Baru (badge abu) | [Edit][Hapus]
PT Pertamina | Sari Anggraini | Deal (hijau) | BUMN | Existing (badge navy) | [Edit][Hapus]
PT Garuda Indonesia | Rina Wijaya | Prospek (biru) | Enterprise | Baru (badge abu) | [Edit][Hapus]
BPJS Kesehatan | Rina Wijaya | Negosiasi (amber) | Government | Existing (badge navy) | [Edit][Hapus]

LABEL "Existing" vs "Baru":

- "Existing": badge solid navy #1E3A5F, teks putih kecil — artinya sudah punya proyek lain berstatus Deal/Kontrak
- "Baru": badge outline abu, teks abu — proyek pertama atau belum ada proyek Deal/Kontrak lain
- Tooltip/catatan kecil di bawah tabel: "Label Existing dihitung otomatis berdasarkan riwayat proyek Deal/Kontrak."

STATUS PELUANG: Prospek=biru · Negosiasi=amber · Deal=hijau · Batal=merah
Catatan: "Status Peluang berbeda dari label Existing/Baru."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 07 — KONTRAK PAYUNG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman daftar Kontrak Payung untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Kontrak Payung" · "+ Tambah Kontrak Payung" kanan atas

KPI MINI (3 kartu kecil di bawah header):

- Total Kontrak: 5
- Masih Berlaku: 3 (badge hijau)
- Kontrak Biasa Turunan: 12

TABEL:
Kolom: No. Kontrak · Nama Kontrak · Customer · Periode Berlaku · Kontrak Biasa (count) · Status · Aksi

KP-TSEL-2025 | Kontrak Payung Layanan TI Telkom 2025–2026 | PT Telkom Indonesia | 01 Jan 2025 — 31 Des 2026 | 4 | Berlaku (hijau) | [Lihat][Edit][Hapus]
KP-MANDIRI-2026 | Master Agreement Core Banking 2026 | PT Bank Mandiri | 01 Jan 2026 — 31 Des 2026 | 2 | Berlaku (hijau) | [Lihat][Edit][Hapus]
KP-PLN-2025 | Kontrak Payung SCADA & Integrasi | PT PLN (Persero) | 01 Mar 2025 — 28 Feb 2026 | 3 | Kedaluwarsa (merah muda) | [Lihat][Edit][Hapus]
KP-PERTH-2026 | Payung ERP & Data Platform 2026 | PT Pertamina | 01 Feb 2026 — 31 Jan 2027 | 1 | Berlaku (hijau) | [Lihat][Edit][Hapus]
KP-BRI-2025 | Master Agreement Digital Channel | PT Bank BRI | 01 Jun 2025 — 31 Mei 2026 | 2 | Kedaluwarsa (merah muda) | [Lihat][Edit][Hapus]

STATUS KONTRAK: Berlaku=hijau · Kedaluwarsa=merah muda
Catatan: "Status dihitung otomatis dari Tanggal Berlaku Selesai vs hari ini."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 08 — SALES MATRIX
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Sales Matrix untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Sales Matrix" · filter Tahun: 2026 · toggle [Per Unit][Per Triwulan] · Export Excel (hanya tampil jika role bukan Assistant Manager)

MODE AKTIF: Per Unit

LEGENDA WARNA (kanan atas):
● ≥100% hijau · ● 60–99% amber · ● <60% merah

TABEL MATRIKS (unit organisasi vs TW):
Kolom: Unit Organisasi | TW1 Jan–Mar | TW2 Apr–Jun | TW3 Jul–Sep | TW4 Okt–Des | Total Tahun

Setiap sel TW berisi DUA baris: TARGET (abu kecil) dan REALISASI (hijau/amber/merah bold) + persentase pencapaian

DATA:
DES | TW1: T:400M R:390M 98% (amber) | TW2: T:450M R:451M 100% (hijau) | TW3: T:500M R: — % | TW4: T:550M R: — % | T:1,9M R:841M 44%
BILL | TW1: T:500M R:620M 124%(hijau) | TW2: T:600M R:480M 80%(amber) | TW3: T:550M R: — % | TW4: T:650M R: — % | T:2,3M R:1,1M 48%
POS | TW1: T:300M R:180M 60%(merah) | TW2: T:350M R:200M 57%(merah) | TW3: T:400M R: — % | TW4: T:450M R: — % | T:1,5M R:380M 25%
SD | TW1: T:600M R:600M 100%(hijau) | TW2: T:700M R:550M 79%(amber) | TW3: T:700M R: — % | TW4: T:750M R: — % | T:2,75M R:1,15M 42%
SE | TW1: T:250M R:310M 124%(hijau) | TW2: T:300M R:295M 98%(amber) | TW3: T:300M R: — % | TW4: T:350M R: — % | T:1,2M R:605M 50%
MKT | TW1: T:200M R:190M 95%(amber) | TW2: T:250M R:248M 99%(amber) | TW3: T:300M R: — % | TW4: T:350M R: — % | T:1,1M R:438M 40%

BARIS TOTAL: background navy muda, teks bold

CATATAN: "SES tidak ditampilkan sebagai baris tersendiri karena bersifat Struktural — target dicatat di Service Delivery (SD) dan Strategic Enablement (SE)."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 09 — PEMBAYARAN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Pembayaran untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Pembayaran" (pengeluaran terikat proyek) · "+ Tambah Pengajuan" kanan atas

KPI MINI (3 kartu):

- Pengajuan Berjalan: 3 (amber)
- Total Disetujui Bulan Ini: Rp 85 Jt (hijau)
- Total Ditolak Bulan Ini: 2 (merah)

FILTER BAR: Status (Semua/Pengajuan/Approved/Rejected) · Proyek (search) · Tanggal

TABEL:
Kolom: ID · Proyek · Kategori · Nilai · Tgl Pengajuan · Tgl Realisasi · Status · Diajukan Oleh · Aksi

PAY-2026-021 | PRJ-PLN-2026 | Subkon DBA | Rp 45.000.000 | 08 Jul 2026 | — | Pengajuan (amber) | Dimas Saputra | [Lihat][Setujui][Tolak]
PAY-2026-020 | PRJ-MANDIRI-2026 | Lisensi Software | Rp 12.000.000 | 07 Jul 2026 | — | Pengajuan (amber) | Budi Santoso | [Lihat][Setujui][Tolak]
PAY-2026-019 | PRJ-TELKOM-2026 | Perjalanan Dinas | Rp 8.500.000 | 06 Jul 2026 | — | Pengajuan (amber) | Andi Pratama | [Lihat][Setujui][Tolak]
PAY-2026-018 | PRJ-BNI-2026 | Subkon Testing | Rp 30.000.000 | 01 Jul 2026 | 03 Jul 2026 | Approved (hijau) | Rina Wijaya | [Lihat]
PAY-2026-017 | PRJ-KAI-2026 | Konsultasi Hukum | Rp 15.000.000 | 28 Jun 2026 | — | Rejected (merah) | Sari Anggraini | [Lihat][Revisi]

CATATAN ATURAN APPROVAL (info box biru muda di atas tabel):
"Pengajuan dari unit Finance disetujui oleh Direktur Utama. Pengajuan unit lain disetujui oleh Finance.
Pengajuan ditolak dapat direvisi dan diajukan kembali tanpa membuat pengajuan baru."

AKSI KONTEKSTUAL (tampil sesuai role):

- Finance/Direktur Utama yang berwenang: tampil [Setujui][Tolak]
- Pengaju dengan status Rejected: tampil [Revisi]
- Status Approved: hanya [Lihat]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 10 — CHART CASHFLOW
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Chart Cashflow untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Chart Cashflow" · filter Tahun: 2026

KPI CARDS (4 kartu):

- Total Inflow YTD: Rp 22,4 M (+18% vs tahun lalu) — hijau
- Total Outflow YTD: Rp 15,2 M (+8% vs tahun lalu) — merah
- Net Cashflow YTD: Rp 7,2 M (Surplus positif) — biru
- Posisi Kas: Rp 12,8 M (Kondisi aman) — navy

CHART AREA (card besar):

- Judul: "Grafik Arus Kas Bulanan (Jan–Jun 2026)"
- Legenda: ■ Inflow (biru) ■ Outflow (oranye)
- Grouped bar chart 6 bulan, setiap bulan 2 bar berdampingan
- Data:
  Jan: Inflow 2,8M · Outflow 2,1M
  Feb: Inflow 3,5M · Outflow 2,4M
  Mar: Inflow 3,2M · Outflow 2,6M
  Apr: Inflow 5,8M · Outflow 3,1M (bar inflow tertinggi, highlight)
  Mei: Inflow 4,2M · Outflow 2,8M
  Jun: Inflow 2,9M · Outflow 2,2M

TABEL REKAP (di bawah chart):
Judul: "Rekap Arus Kas Bulanan"
Kolom: Bulan · Inflow · Outflow · Net Cashflow
6 baris data + baris Total YTD (background navy muda bold)
Net Cashflow: positif=hijau, negatif=merah

SUMBER DATA (info note kecil):
"Inflow dihitung dari Pencairan Tagihan berstatus Parsial/Final.
Outflow dihitung dari Pembayaran dan Pengeluaran Perusahaan yang Approved dengan Tanggal Realisasi terisi.
Posisi Kas bertitik tolak dari Saldo Awal Kas terakhir yang tercatat."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 11 — KARYAWAN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Karyawan untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Karyawan" · "+ Tambah Karyawan" kanan atas

FILTER BAR: Search (NIK/nama) · Unit (dropdown tree) · Jabatan · Status (Aktif/Tidak Aktif)

TABEL (8 baris):
Kolom: Avatar+Nama · NIK · Jabatan · Unit · Email · Status · Akun IS · Aksi

CL Citra Lestari | SWA-001 | Manager Marketing & Sales | MKT | citra@swamedia.co.id | Aktif | ✓ Terhubung | [Edit][Hapus]
AP Andi Pratama | SWA-002 | System Analyst | DES | andi@swamedia.co.id | Aktif | ✓ Terhubung | [Edit][Hapus]
DS Dimas Saputra | SWA-003 | Project Manager Officer | PMO | dimas@swamedia.co.id | Aktif | ✓ Terhubung | [Edit][Hapus]
RW Rina Wijaya | SWA-004 | Backend Developer | DES | rina@swamedia.co.id | Aktif | ✓ Terhubung | [Edit][Hapus]
BS Budi Santoso | SWA-005 | Database Developer | BILL | budi@swamedia.co.id | Aktif | ✓ Terhubung | [Edit][Hapus]
SA Sari Anggraini | SWA-006 | Frontend Developer | POS | sari@swamedia.co.id | Aktif | ✗ Belum (abu) | [Edit][Hapus]
AF Ahmad Fauzi | SWA-007 | Software Tester | SD | ahmad@swamedia.co.id | Aktif | ✗ Belum (abu) | [Edit][Hapus]
MI Maya Indah | SWA-008 | UI/UX Designer | SE | maya@swamedia.co.id | Tidak Aktif (abu) | ✗ Belum | [Edit][Hapus]

KOLOM "Akun IS":

- ✓ Terhubung (hijau kecil): subject_id sudah diisi → karyawan punya akun login
- ✗ Belum (abu): subject_id kosong → belum bisa login ke Portal
- Tooltip: "Hubungkan akun IS melalui Manajemen User → salin Subject ID ke field ini"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 12 — MANAJEMEN USER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Manajemen User untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Manajemen User"
SUBTITLE: "Data pengguna dikelola melalui WSO2 Identity Server. Portal mengirim permintaan ke IS melalui layanan Ballerina."

- Tambah User (kanan atas) · Filter Role

TABEL (6 baris):
Kolom: Avatar+Nama · Email · Role (badge warna) · Status · Terakhir Login · Aksi

AP Andi Pratama | andi@swamedia.co.id | Manager (biru) | Aktif (hijau) | 13 Jul 2026, 08:42 | [Edit][Reset PW][Lihat Profil]
BS Budi Santoso | budi@swamedia.co.id | Finance (amber) | Aktif (hijau) | 12 Jul 2026, 14:30 | [Edit][Reset PW][Lihat Profil]
CL Citra Lestari | citra@swamedia.co.id | Manager (biru) | Aktif (hijau) | 13 Jul 2026, 09:15 | [Edit][Reset PW][Lihat Profil]
DA Dewi Anggraini | dewi@swamedia.co.id | Finance (amber) | Aktif (hijau) | 11 Jul 2026, 11:00 | [Edit][Reset PW][Lihat Profil]
EW Eko Wijaya | eko@swamedia.co.id | Direktur (navy) | Tidak Aktif (abu) | 01 Jun 2026, 09:00 | [Aktifkan][Lihat Profil]
RW Rina Wijaya | rina@swamedia.co.id | Assistant Manager (ungu) | Aktif (hijau) | 13 Jul 2026, 07:30 | [Edit][Reset PW][Lihat Profil]

ROLE BADGE WARNA:
Super Admin: hitam · Direktur: navy (#1E3A5F) · Manager: biru (#2563EB) · Assistant Manager: ungu (#7C3AED) · Finance: amber (#D97706)

INFO BOX AMBER DI ATAS TABEL:
"Seluruh operasi tambah/ubah/hapus user diteruskan ke WSO2 Identity Server melalui layanan Ballerina menggunakan kredensial aplikasi. Data di halaman ini adalah tampilan baca dari hasil sinkronisasi."

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 13 — NOTIFIKASI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Notifikasi untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Notifikasi" · badge "3 Belum Dibaca" (merah) · tombol "Tandai Semua Dibaca" (kanan)

TAB FILTER: [Semua] [Penugasan] [Status] [Sistem]

FEED NOTIFIKASI (8 item, campuran baca/belum):

🔵 BELUM DIBACA (highlight latar biru sangat muda):
[Ikon biru] PENUGASAN — "Anda ditambahkan sebagai Project Manager Officer pada PRJ-TELKOM-2026" · "Lihat Proyek →" · 24 Jun 2026, 09:15

[Ikon biru] PENUGASAN — "Anda ditambahkan sebagai Backend Developer pada PRJ-MANDIRI-2026. Periode: 2026-Q3" · "Lihat Proyek →" · 23 Jun 2026, 14:30

[Ikon amber] SISTEM — "Target Sales Unit 'BILL' TW2 2026 belum mencapai 80% dari target. Pantau pipeline." · "Lihat Target →" · 23 Jun 2026, 08:00

⚪ SUDAH DIBACA (normal, tanpa highlight):
[Ikon hijau] STATUS — "Tagihan INV-2026-031 untuk PRJ-BNI-2026 berubah menjadi Lunas." · "Lihat Tagihan →" · 20 Jun 2026, 16:45

[Ikon biru] PENUGASAN — "Anda ditambahkan sebagai Database Developer pada PRJ-BCA-2026. Periode: 2026-Q2" · "Lihat Proyek →" · 18 Jun 2026, 11:20

[Ikon abu] SISTEM — "Sinkronisasi data pengguna dari IS berhasil. 3 akun diperbarui." · 17 Jun 2026, 02:00

[Ikon hijau] STATUS — "Status PRJ-TELKOM-2026 diperbarui menjadi Deal/Kontrak oleh Andi Pratama." · "Lihat Proyek →" · 15 Jun 2026, 10:05

[Ikon amber] SISTEM — "Kontrak Payung KP-TSEL-2025 akan berakhir dalam 30 hari (31 Jul 2026). Tinjau pembaruan." · "Lihat Kontrak →" · 01 Jun 2026, 00:00

PAGINATION: "Menampilkan 8 dari 24 notifikasi" + tombol "Muat Lebih Banyak"

LINK DEEP-LINK (teks biru kecil di kanan setiap item): "Lihat Proyek →" / "Lihat Tagihan →" / "Lihat Target →" / "Lihat Kontrak →"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 14 — AUDIT LOG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Audit Log untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Audit Log" · badge "Admin Only" (abu) · Tombol "Export CSV" kanan atas

KPI MINI ROW (3 kartu kecil):
Total Log (30 hari): 156 | CREATE: 48 (hijau) | UPDATE: 91 (amber) | DELETE: 17 (merah)

FILTER BAR: Modul (dropdown) · Aksi (Semua/CREATE/UPDATE/DELETE) · Cari aktor · Rentang tanggal · [Reset Filter]

TABEL (12 baris):
Kolom: Waktu · Modul (badge warna) · Record ID · Aksi · Aktor · IP Address · Perubahan

02 Jul 2026, 14:32 | Proyek (navy) | PRJ-TELKOM-2026 | UPDATE (amber) | AP Andi Pratama | 10.20.1.45 | "2 field berubah"
02 Jul 2026, 13:58 | Pencairan (hijau) | INV-2026-087 | CREATE (hijau) | RW Rina Wijaya | 10.20.1.62 | "Record baru dibuat"
02 Jul 2026, 13:20 | Kontrak Payung (biru) | KP-2026-012 | UPDATE (amber) | DS Dimas Saputra | 10.20.2.11 | "2 field berubah"
02 Jul 2026, 11:44 | Karyawan (ungu) | KRY-0045 | CREATE (hijau) | SA Sari Anggraini | 10.20.1.88 | "Record baru dibuat"
02 Jul 2026, 10:15 | Proyek (navy) | PRJ-PLN-2026 | UPDATE (amber) | DS Dimas Saputra | 10.20.2.11 | "2 field berubah"
01 Jul 2026, 16:47 | Kontrak Biasa (biru) | KB-2026-031 | CREATE (hijau) | AP Andi Pratama | 10.20.1.45 | "Record baru dibuat"
01 Jul 2026, 15:30 | Nomor Surat (abu) | SK-DR-02-2026-018 | CREATE (hijau) | RW Rina Wijaya | 10.20.1.62 | "Record baru dibuat"
01 Jul 2026, 14:02 | Customer (oranye) | CUST-0098 | UPDATE (amber) | SA Sari Anggraini | 10.20.1.88 | "2 field berubah"
01 Jul 2026, 11:18 | Pembayaran (merah) | PAY-2026-086 | UPDATE (amber) | RW Rina Wijaya | 10.20.1.62 | "Status: PENGAJUAN→APPROVED"
01 Jun 2026, 09:55 | Unit Share (teal) | TM-PRJ-PLN-0003 | CREATE (hijau) | DS Dimas Saputra | 10.20.2.11 | "Record baru dibuat"
30 Jun 2026, 17:22 | Proyek (navy) | PRJ-MANDIRI-2026 | UPDATE (amber) | DS Dimas Saputra | 10.20.2.11 | "1 field berubah"
30 Jun 2026, 15:48 | Kontrak Payung (biru) | KP-2026-011 | DELETE (merah) | SA Sari Anggraini | 10.20.1.88 | "Record dihapus"

AKSI BADGE: CREATE=hijau · UPDATE=amber · DELETE=merah
KLIK "Perubahan" → expand baris menampilkan detail field sebelum/sesudah

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HALAMAN 15 — KONFIGURASI SISTEM
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Buat halaman Konfigurasi Sistem untuk Swamedia Project Website Portal.

[KONTEKS UMUM di atas berlaku]

HEADER: "Konfigurasi Sistem" · subtitle "Pengaturan umum yang berlaku untuk seluruh pengguna portal"
Tombol "Simpan Semua Perubahan" (biru, kanan atas)

SECTION 1 — Penomoran & Format (ikon pensil):

- Prefix Kode Proyek: [PRJ] (input teks)
- Format Kode Proyek: [Prefix]-[Customer]-[Tahun] (read-only, teks abu)
- Prefix Nomor Surat: [SK] (input teks)
- Format Tanggal: dropdown [DD/MM/YYYY]
- Format Mata Uang: dropdown [IDR (Rp)]

SECTION 2 — Notifikasi (ikon lonceng):

- Email notif. Team Members: toggle ON/OFF [ON — Aktif]
- Maks. waktu kirim (menit): [1]
- Email pengirim: [no-reply@swamedia.co.id]
- Info box hijau: "Email notifikasi aktif. Karyawan akan menerima email saat ditambahkan sebagai Team Member pada proyek."

SECTION 3 — Sinkronisasi Identity Server (ikon sinkronisasi):

- URL SCIM2 Endpoint: [https://iam.apicentrum.biz.id/scim2/Users] (read-only, dengan ikon gembok kanan)
- Jadwal Reconciliation: dropdown [Setiap hari pukul 02:00]
- Last Sync: 24 Jun 2026, 02:00 · badge "✓ Berhasil" (hijau)
- Tombol besar full-width: "↻ Jalankan Sync Sekarang" (outline biru)

SECTION 4 — Informasi Sistem (ikon info):

- Nama Aplikasi: Swamedia Project Website Portal (read-only)
- Versi: 2.0.0 (read-only, dari environment variable)
- Environment: Production (badge hijau, read-only)
- Catatan abu kecil: "Informasi Versi dan Environment dibaca dari konfigurasi deployment, tidak dapat diubah melalui halaman ini."

STICKY FOOTER (saat scroll): "Perubahan akan berlaku setelah disimpan." + [Batal] [Simpan Semua Perubahan]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MODAL / DIALOG PENTING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

MODAL TAMBAH PROYEK:

- Judul: "Tambah Proyek Baru"
- Field wajib (\*): Nama Proyek · Customer (dropdown searchable) · Industri · Unit (dropdown, hanya unit OPERASIONAL/leaf) · Nilai Proyek · Subkon · PIC Sales (dropdown karyawan) · Status awal selalu "Info Peluang" (read-only)
- Field opsional: PMO · Departemen · Target Selesai · Kontrak Payung (dropdown)
- Info: "Kode proyek digenerate otomatis setelah disimpan: [PRJ]-[KODE_CUSTOMER]-[TAHUN]"
- Tombol: [Batal] [Simpan]

MODAL UPDATE STATUS PROYEK:

- Judul: "Update Status Proyek"
- Field: Status Baru* (dropdown 7 nilai enum) · Komentar* · Tanggal\*
- Info amber jika status = Deal/Kontrak: "Tanggal Deal akan dicatat otomatis hari ini sebagai dasar Realisasi Sales triwulan ini."
- Tombol: [Batal] [Simpan Status]

MODAL TAMBAH PENCAIRAN:

- Judul: "Tambah Pencairan — [No. Tagihan]"
- Field: Tanggal Pencairan* · Nilai* · Status\* (Parsial/Final) · Keterangan
- Warning merah: "Pencairan yang disimpan berstatus Parsial/Final bersifat final dan tidak dapat di-reverse."
- Tombol: [Batal] [Simpan]

MODAL TOLAK PENGAJUAN (Pembayaran/Pengeluaran):

- Judul: "Tolak Pengajuan"
- Field: Catatan Penolakan\* (textarea wajib)
- Info biru: "Pengaju dapat merevisi pengajuan yang ditolak dan mengajukannya kembali tanpa membuat pengajuan baru."
- Tombol: [Batal] [Tolak Pengajuan] (merah)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PANDUAN PEMAKAIAN PROMPT INI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. Buka Claude Design (https://claude.ai/design)
2. Buat project baru bernama "Swamedia Portal v2"
3. Untuk setiap halaman:
   a. Salin seluruh teks KONTEKS UMUM (blok pertama)
   b. Tambahkan satu blok [HALAMAN XX] di bawahnya
   c. Kirim sebagai satu prompt
4. Setelah halaman dihasilkan, gunakan fitur follow-up untuk:
   - "Sesuaikan warna badge status agar konsisten dengan design system"
   - "Tampilkan versi mobile dari halaman ini"
   - "Tambahkan empty state untuk tabel yang kosong"
   - "Buat versi dark mode"
5. Urutan yang disarankan: 01 → 02 → 03 → 05 → 08 → 09 → 10 → 11 → dst.
   (Dashboard dulu untuk menetapkan look & feel, lalu halaman fungsional utama)

CATATAN KONSISTENSI:

- JANGAN gunakan istilah "Issue Open" — tidak ada di PRD v2.0
- JANGAN tampilkan role "PMO" atau "Sales/BD" — role resmi hanya 5 (lihat RBAC ROLE)
- JANGAN tampilkan "nilai_cair" sebagai kolom Tagihan — dihitung dari agregasi Pencairan
- SELALU tampilkan "SES" sebagai Struktural, bukan baris target — target ada di SD dan SE
- SELALU gunakan label status proyek sesuai enum (bukan "Proses Proposal/BoQ", dll.)
