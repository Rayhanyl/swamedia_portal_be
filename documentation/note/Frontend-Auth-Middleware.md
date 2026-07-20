# Implementasi Auth & Middleware di Frontend

Dokumen ini adalah panduan implementasi untuk **tim frontend** yang
mengonsumsi BFF auth (`/api/v1/auth/*`) milik `swamedia_portal_be`. Lihat
[Auth-Redis-DB.md](Auth-Redis-DB.md) untuk detail backend-nya; dokumen ini
fokus ke sisi klien: cara login, menyimpan token, memasang token ke request,
auto-refresh, proteksi halaman, dan logout.

Arsitektur yang dipakai di sini menambahkan **satu lapis BFF lagi di sisi
Next.js**, di depan BFF Ballerina yang sudah ada:

```text
Browser  --same-origin-->  Next.js (proxy.ts + route handler login/logout)  --server-to-server-->  Ballerina BFF  --->  WSO2 IS
```

Konsekuensinya: **token WSO2 (access/refresh/id token) tidak pernah
menyentuh JavaScript di browser**. Semua disimpan sebagai cookie `httpOnly`
yang di-set oleh Next.js sendiri, dan setiap request ke Ballerina backend
ditempelkan token-nya oleh `proxy.ts` di server Next.js — bukan oleh kode
yang jalan di browser. Ini menggantikan pendekatan lama (interceptor di
browser yang menempelkan `Authorization` header + `middleware.ts` edge yang
cuma cek keberadaan cookie): browser sekarang tidak pernah tahu bentuk token
sama sekali, jadi risiko XSS-mencuri-token hilang.

Contoh kode pakai TypeScript + Next.js App Router (Route Handlers), karena
konsep "middleware proxy" ini paling natural diimplementasikan di situ. Kalau
stack FE bukan Next.js, pola yang sama tetap berlaku — gantikan Route Handler
dengan endpoint server side apa pun yang tersedia (Nuxt server routes, Express
di belakang Vite, dsb.), selama tetap satu proses server yang memegang token,
terpisah dari kode yang jalan di browser.

---

## 1. Kontrak API yang perlu diketahui

### 1.1 Envelope response

**Semua** response backend (sukses maupun error) dibungkus format yang sama:

```ts
interface ApiResponse<T> {
  success: boolean;
  message: string;
  data?: T;
  errors: { code: string; message: string; details?: unknown } | null;
  meta: { timestamp: string; pagination?: Pagination };
}
```

Jadi jangan langsung `response.data` sebagai payload — selalu unwrap lewat
`body.data`, dan cek `body.success` (atau HTTP status) untuk tahu error atau
tidak.

### 1.2 Endpoint auth yang dipakai frontend

| Method | Endpoint | Body | Kapan dipakai |
| --- | --- | --- | --- |
| `POST` | `/api/v1/auth/login` | `{ username, password }` | Form login — cara paling umum, satu request langsung dapat token + user |
| `POST` | `/api/v1/auth/refresh` | `{ refreshToken }` | Access token kedaluwarsa, ditukar otomatis oleh `proxy.ts` |
| `GET` | `/api/v1/auth/userinfo` | header `Authorization: Bearer <accessToken>` | Ambil ulang klaim user (dipakai cache 60 detik di backend) |
| `POST` | `/api/v1/auth/introspect` | `{ token, tokenTypeHint? }` | Cek valid/tidaknya token tanpa memakainya (jarang perlu di FE, backend/JWKS sudah validasi tiap request) |
| `POST` | `/api/v1/auth/revoke` | `{ token, tokenTypeHint? }` | Cabut access/refresh token secara eksplisit |
| `POST` | `/api/v1/auth/logout` | `{ idToken }` | Akhiri sesi user di WSO2 IS saat user klik logout |

`/init` dan `/token` (authorization_code exchange) hanya perlu dipakai kalau
frontend ingin mengontrol pilihan authenticator sendiri; untuk kasus
username/password biasa, `/login` sudah cukup dan **direkomendasikan**.

Semua endpoint di atas dipanggil **dari server Next.js** (route handler
login/logout, atau dari `proxy.ts`), bukan langsung dari browser.

### 1.3 Bentuk response `login`

```ts
interface LoginResponse {
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  tokenType: string;   // "Bearer"
  expiresIn: number;   // detik
  scope?: string;
  user: Record<string, unknown>; // klaim id_token: sub, email, name, dst.
}
```

`data` di `ApiResponse` untuk endpoint `/login`, `/token`, dan `/refresh`
berbentuk `LoginResponse` di atas.

### 1.4 Kode error yang mungkin muncul

Field `errors.code` dari `models:AppError` backend, yang paling relevan buat
FE:

| Code | Status | Arti | Aksi FE yang disarankan |
| --- | --- | --- | --- |
| `UNAUTHORIZED` | 401 | Username/password salah, atau access token invalid/expired | Login gagal → tampilkan pesan; kalau dari `proxy.ts` → coba refresh, gagal → hapus cookie & redirect ke halaman login |
| `VALIDATION_ERROR` | 400 | Body request tidak valid | Tampilkan pesan error ke user (pesan asli aman ditampilkan, lihat [Auth-Redis-DB.md §1.6](Auth-Redis-DB.md#16-penanganan-error--keamanan-pesan)) |
| `INTERNAL_ERROR` | 500 | Error server (pesan sudah digenerik-kan backend) | Tampilkan pesan generik + tombol retry |

---

## 2. Session cookies (helper bersama)

Tiga token disimpan sebagai cookie `httpOnly` terpisah, di-set/dibaca lewat
Next.js `cookies()` API (Route Handlers & Server Components). `httpOnly`
berarti JavaScript di browser **tidak bisa** membacanya sama sekali —
mitigasi utama terhadap pencurian token lewat XSS.

```ts
// lib/auth/session-cookies.ts
import { cookies } from "next/headers";

const ACCESS_TOKEN = "swamedia_access_token";
const REFRESH_TOKEN = "swamedia_refresh_token";
const ID_TOKEN = "swamedia_id_token";

const baseCookieOptions = {
  httpOnly: true,
  secure: process.env.NODE_ENV === "production",
  sameSite: "lax" as const,
  path: "/",
};

export async function setSessionCookies(tokens: {
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  expiresIn: number; // detik, dari LoginResponse.expiresIn
}) {
  const jar = await cookies();
  jar.set(ACCESS_TOKEN, tokens.accessToken, {
    ...baseCookieOptions,
    maxAge: tokens.expiresIn,
  });
  if (tokens.refreshToken) {
    // Refresh token berumur jauh lebih panjang dari access token di WSO2 IS;
    // maxAge di sini sengaja dilebihkan supaya proxy.ts yang menentukan
    // kapan token sudah tidak valid (lewat respons 401 dari backend), bukan
    // cookie expiry yang menebak-nebak umur refresh token.
    jar.set(REFRESH_TOKEN, tokens.refreshToken, { ...baseCookieOptions, maxAge: 60 * 60 * 24 * 30 });
  }
  if (tokens.idToken) {
    jar.set(ID_TOKEN, tokens.idToken, { ...baseCookieOptions, maxAge: 60 * 60 * 24 * 30 });
  }
}

export async function getSessionCookies() {
  const jar = await cookies();
  return {
    accessToken: jar.get(ACCESS_TOKEN)?.value,
    refreshToken: jar.get(REFRESH_TOKEN)?.value,
    idToken: jar.get(ID_TOKEN)?.value,
  };
}

export async function clearSessionCookies() {
  const jar = await cookies();
  jar.delete(ACCESS_TOKEN);
  jar.delete(REFRESH_TOKEN);
  jar.delete(ID_TOKEN);
}
```

---

## 3. Route handler login & logout

Dua endpoint Next.js ini adalah **satu-satunya** tempat browser mengirim
username/password, dan satu-satunya tempat cookie session di-set/dihapus.

```ts
// app/api/login/route.ts
import { NextRequest, NextResponse } from "next/server";
import { setSessionCookies } from "@/lib/auth/session-cookies";

const BACKEND_BASE = process.env.BACKEND_BASE_URL ?? "http://localhost:8080";

export async function POST(req: NextRequest) {
  const { username, password } = await req.json();

  const res = await fetch(`${BACKEND_BASE}/api/v1/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password }),
  });
  const body = await res.json();

  if (!res.ok || !body.success) {
    return NextResponse.json(
      { message: body.errors?.message ?? body.message },
      { status: res.status },
    );
  }

  await setSessionCookies(body.data);
  // Browser hanya menerima data user, TIDAK PERNAH menerima token mentah.
  return NextResponse.json({ user: body.data.user });
}
```

```ts
// app/api/logout/route.ts
import { NextResponse } from "next/server";
import { getSessionCookies, clearSessionCookies } from "@/lib/auth/session-cookies";

const BACKEND_BASE = process.env.BACKEND_BASE_URL ?? "http://localhost:8080";

export async function POST() {
  const { idToken } = await getSessionCookies();

  if (idToken) {
    // Best-effort: kalaupun WSO2 IS tidak terjangkau, tetap lanjut hapus cookie
    // lokal supaya user tidak "terjebak login" di browser-nya sendiri.
    await fetch(`${BACKEND_BASE}/api/v1/auth/logout`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idToken }),
    }).catch(() => {});
  }

  await clearSessionCookies();
  return NextResponse.json({ success: true });
}
```

---

## 4. `proxy.ts` — titik tunggal yang menempelkan token & auto-refresh

Ini menggantikan pendekatan lama (interceptor Axios/fetch di browser +
`middleware.ts` edge yang cuma cek keberadaan cookie). Sekarang **satu**
Route Handler catch-all meneruskan setiap request bisnis ke Ballerina
backend, menempelkan `Authorization: Bearer <accessToken>` dari cookie, dan
otomatis refresh sekali kalau backend balas 401.

```ts
// app/api/proxy/[...path]/route.ts  (proxy.ts)
import { NextRequest, NextResponse } from "next/server";
import { getSessionCookies, setSessionCookies, clearSessionCookies } from "@/lib/auth/session-cookies";

const BACKEND_BASE = process.env.BACKEND_BASE_URL ?? "http://localhost:8080";

async function refreshAccessToken(refreshToken: string) {
  const res = await fetch(`${BACKEND_BASE}/api/v1/auth/refresh`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refreshToken }),
  });
  const body = await res.json();
  if (!res.ok || !body.success) return null;
  return body.data as { accessToken: string; refreshToken?: string; expiresIn: number };
}

async function forward(req: NextRequest, path: string[]) {
  const { accessToken, refreshToken } = await getSessionCookies();
  const targetUrl = `${BACKEND_BASE}/api/v1/${path.join("/")}${req.nextUrl.search}`;
  const body = req.method === "GET" || req.method === "HEAD" ? undefined : await req.text();

  const doFetch = (token?: string) =>
    fetch(targetUrl, {
      method: req.method,
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body,
    });

  let res = await doFetch(accessToken);

  if (res.status === 401 && refreshToken) {
    const refreshed = await refreshAccessToken(refreshToken);
    if (!refreshed) {
      await clearSessionCookies();
      return NextResponse.json(
        { success: false, message: "Session expired" },
        { status: 401 },
      );
    }
    await setSessionCookies({ ...refreshed, refreshToken: refreshed.refreshToken ?? refreshToken });
    res = await doFetch(refreshed.accessToken);
  }

  const responseBody = await res.text();
  return new NextResponse(responseBody, {
    status: res.status,
    headers: { "Content-Type": "application/json" },
  });
}

export async function GET(req: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  return forward(req, (await params).path);
}
export async function POST(req: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  return forward(req, (await params).path);
}
export async function PUT(req: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  return forward(req, (await params).path);
}
export async function DELETE(req: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  return forward(req, (await params).path);
}
```

Karena leg `browser → Next.js` ini **same-origin** (browser hanya pernah
memanggil `/api/proxy/...` di domain-nya sendiri) dan leg `Next.js → Ballerina
backend` adalah panggilan server-to-server, **CORS browser tidak pernah jadi
masalah untuk jalur ini** — CORS hanya berlaku untuk request yang dikirim
langsung oleh JavaScript browser ke origin lain (lihat bagian 8 soal kenapa
backend tetap dikonfigurasi CORS-nya).

---

## 5. Client API helper (dipanggil dari komponen React)

Karena token sudah ditangani sepenuhnya oleh `proxy.ts`, kode di browser
jadi jauh lebih sederhana — cukup panggil path relatif, tanpa header
`Authorization` apa pun:

```ts
// lib/api-client.ts
interface ApiResponse<T> {
  success: boolean;
  message: string;
  data?: T;
  errors: { code: string; message: string } | null;
}

async function unwrap<T>(res: Response): Promise<T> {
  const body: ApiResponse<T> = await res.json();
  if (!res.ok || !body.success) {
    if (res.status === 401) window.location.href = "/login";
    throw new Error(body.errors?.message ?? body.message);
  }
  return body.data as T;
}

export const apiClient = {
  get: <T>(path: string) => fetch(`/api/proxy/${path}`).then((res) => unwrap<T>(res)),
  post: <T>(path: string, payload: unknown) =>
    fetch(`/api/proxy/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    }).then((res) => unwrap<T>(res)),
  put: <T>(path: string, payload: unknown) =>
    fetch(`/api/proxy/${path}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    }).then((res) => unwrap<T>(res)),
  delete: <T>(path: string) =>
    fetch(`/api/proxy/${path}`, { method: "DELETE" }).then((res) => unwrap<T>(res)),
};

// contoh: apiClient.get("master/units?page=1") -> memanggil
// GET /api/v1/master/units?page=1 di backend, lewat proxy.ts, dengan token
// yang ditempelkan otomatis.
```

---

## 6. State auth di aplikasi (React contoh)

```tsx
// context/AuthContext.tsx
import { createContext, useContext, useState, ReactNode } from "react";

interface AuthState {
  user: Record<string, unknown> | null;
  login: (username: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children, initialUser }: { children: ReactNode; initialUser: Record<string, unknown> | null }) {
  const [user, setUser] = useState(initialUser);

  async function login(username: string, password: string) {
    const res = await fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });
    const body = await res.json();
    if (!res.ok) throw new Error(body.message);
    setUser(body.user);
  }

  async function logout() {
    await fetch("/api/logout", { method: "POST" }).catch(() => {});
    setUser(null);
    window.location.href = "/login";
  }

  return <AuthContext.Provider value={{ user, login, logout }}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
```

`initialUser` di atas diisi dari Server Component root layout, yang
membaca cookie `swamedia_access_token` lewat `getSessionCookies()` dan
memanggil `/api/v1/auth/userinfo` (via backend langsung, server-to-server)
kalau perlu re-hydrate klaim user setelah refresh halaman — tidak perlu
lewat `proxy.ts` karena ini jalan di server, bukan di browser.

---

## 7. Proteksi halaman

Karena token tidak lagi dibaca dari `localStorage`, cek "apakah user login"
untuk keperluan redirect halaman cukup berupa **cek keberadaan** cookie
`swamedia_access_token` — validitas token yang sesungguhnya tetap
diverifikasi backend lewat JWKS setiap kali `proxy.ts` meneruskan request
(lihat [Auth-Redis-DB.md §1.4](Auth-Redis-DB.md#14-proteksi-endpoint-bisnis-dengan-jwt-jwks)); kalau
sudah invalid, `proxy.ts` di bagian 4 yang menangani refresh/kill-session.

Paling sederhana: cek di Server Component per halaman/layout, tanpa
`middleware.ts` edge terpisah:

```tsx
// app/(protected)/layout.tsx
import { redirect } from "next/navigation";
import { getSessionCookies } from "@/lib/auth/session-cookies";

export default async function ProtectedLayout({ children }: { children: React.ReactNode }) {
  const { accessToken } = await getSessionCookies();
  if (!accessToken) redirect("/login");
  return <>{children}</>;
}
```

Kalau butuh proteksi di edge sebelum halaman di-render sama sekali (mis.
supaya asset halaman terproteksi tidak ikut ter-fetch untuk user yang belum
login), boleh tambah `middleware.ts` tipis yang **hanya** cek keberadaan
cookie dan redirect — tapi itu murni optimisasi UX navigasi, bukan lagi
tempat logic auth (attach token, refresh, dsb). Semua logic auth request
sekarang ada di `proxy.ts`.

---

## 8. CORS (backend sudah dikonfigurasi)

`swamedia_portal_be` sekarang mengekspos `corsAllowedOrigins` (lihat
`modules/config/config.bal`) dan menerapkannya lewat `@http:ServiceConfig {
cors: {...} }` di setiap service di `main.bal`, termasuk `/api/v1/auth`.
Default-nya `["http://localhost:3000"]` (port dev Next.js standar) —
override lewat `Config.toml`:

```toml
[rayha.swamedia_portal_be.config]
corsAllowedOrigins = ["https://portal.swamedia.co.id", "http://localhost:3000"]
```

**Penting untuk dipahami dengan pola `proxy.ts` di atas**: karena browser
tidak pernah memanggil backend Ballerina secara langsung (selalu lewat
`/api/proxy/...` yang same-origin), CORS **tidak berperan** dalam alur
aplikasi utama sama sekali — panggilan `Next.js → Ballerina` adalah
server-to-server dan tidak tunduk pada CORS (CORS murni aturan yang
ditegakkan browser). Konfigurasi CORS ini tetap berguna untuk:

- Klien lain yang memang memanggil backend langsung dari browser (mis. tim
  lain membuat internal tool terpisah tanpa proxy Next.js).
- Testing manual dari browser (Swagger UI, dsb.) yang di-serve dari origin
  berbeda dari backend.

Kalau semua konsumen frontend dipastikan lewat pola proxy di dokumen ini,
daftar `corsAllowedOrigins` boleh dibiarkan seminimal mungkin (atau bahkan
hanya origin tools internal) karena bukan jalur pertahanan utama lagi.

---

## 9. Ringkasan alur logout

1. Browser memanggil `POST /api/logout` (Next.js, bukan backend langsung).
2. Route handler membaca `idToken` dari cookie, memanggil
   `POST /api/v1/auth/logout` ke backend (best-effort — kegagalan tidak
   menghentikan proses hapus cookie).
3. Route handler menghapus ketiga cookie sesi.
4. Browser redirect ke halaman login.

Opsional: panggil juga `POST /api/v1/auth/revoke` untuk `refreshToken`
sebelum menghapus cookie, kalau ingin refresh token itu benar-benar tidak
bisa dipakai lagi meski bocor (endpoint ini per-token, bukan per-user).
