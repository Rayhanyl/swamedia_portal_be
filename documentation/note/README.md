# Swamedia Portal Backend

Backend RESTful API untuk project `swamedia_portal_be`, dibuat dengan
Ballerina `2201.13.4`.

Dokumen ini menjelaskan cara memahami struktur project dan cara menambahkan
RESTful API baru secara bertahap.

## Ringkasan Project

Project ini menggunakan package Ballerina:

```toml
[package]
org = "rayha"
name = "swamedia_portal_be"
version = "0.1.0"
distribution = "2201.13.4"
```

Struktur utama project:

```text
swamedia_portal_be/
|-- Ballerina.toml
|-- Dependencies.toml
|-- main.bal
`-- modules/
    |-- config/
    |-- models/
    |-- repositories/
    |-- services/
    `-- utils/
```

Penjelasan folder:

| Lokasi | Fungsi |
| --- | --- |
| `main.bal` | Entry point aplikasi. Cocok untuk mendefinisikan HTTP listener dan resource REST API. |
| `modules/config` | Konfigurasi aplikasi, misalnya port, database config, env config, atau konstanta global. |
| `modules/models` | Definisi tipe data API, seperti request body, response body, dan entity. |
| `modules/repositories` | Layer akses data. Nantinya bisa berisi query database, akses file, atau integrasi storage. |
| `modules/services` | Layer business logic. Resource API sebaiknya memanggil service, bukan langsung repository. |
| `modules/utils` | Helper umum, misalnya formatter response, validator, atau helper error. |

## Arsitektur RESTful API

Pola yang disarankan untuk project ini:

```text
Client
  |
  v
HTTP Resource di main.bal
  |
  v
Service di modules/services
  |
  v
Repository di modules/repositories
  |
  v
Database / storage / external API
```

Alasan pemisahan layer:

1. `main.bal` fokus menerima request HTTP dan mengembalikan response.
2. `services` fokus pada aturan bisnis.
3. `repositories` fokus pada sumber data.
4. `models` membuat tipe data lebih konsisten dan mudah dites.
5. `utils` menyimpan helper agar tidak terjadi duplikasi kode.

## Menjalankan Project

Build project:

```bash
bal build
```

Menjalankan project:

```bash
bal run
```

Menjalankan test:

```bash
bal test
```

Jika REST API menggunakan port `8080`, endpoint lokal biasanya tersedia di:

```text
http://localhost:8080
```

## Cara Membuat RESTful API Baru

Contoh berikut menggunakan resource `articles`.

Endpoint yang akan dibuat:

| Method | Endpoint | Fungsi |
| --- | --- | --- |
| `GET` | `/api/v1/articles` | Mengambil semua artikel. |
| `GET` | `/api/v1/articles/{id}` | Mengambil artikel berdasarkan ID. |
| `POST` | `/api/v1/articles` | Membuat artikel baru. |
| `PUT` | `/api/v1/articles/{id}` | Mengubah artikel berdasarkan ID. |
| `DELETE` | `/api/v1/articles/{id}` | Menghapus artikel berdasarkan ID. |

## 1. Tambahkan Model

Tambahkan tipe data pada `modules/models/models.bal`.

Contoh:

```ballerina
public type Article record {|
    int id;
    string title;
    string content;
    string status;
|};

public type CreateArticleRequest record {|
    string title;
    string content;
|};

public type UpdateArticleRequest record {|
    string title;
    string content;
    string status;
|};

public type ErrorDetail record {|
    string code;
    string message;
    anydata details?;
|};
```

Penjelasan:

| Model | Fungsi |
| --- | --- |
| `Article` | Bentuk data artikel yang dikembalikan ke client. |
| `CreateArticleRequest` | Bentuk request body saat membuat artikel. |
| `UpdateArticleRequest` | Bentuk request body saat mengubah artikel. |
| `ErrorDetail` | Detail error yang dipakai di dalam struktur `ApiResponse`. |

Gunakan `record {| ... |}` agar field yang dikirim lebih ketat. Dengan bentuk
ini, Ballerina membantu menjaga struktur data tetap sesuai kontrak API.

## 2. Tambahkan Repository

Tambahkan fungsi akses data pada `modules/repositories/repositories.bal`.

Contoh repository sederhana dengan data sementara di memory:

```ballerina
import rayha/swamedia_portal_be.models;

final table<models:Article> key(id) articles = table [
    {id: 1, title: "Artikel Pertama", content: "Konten artikel pertama", status: "published"},
    {id: 2, title: "Artikel Kedua", content: "Konten artikel kedua", status: "draft"}
];

public function findAllArticles() returns models:Article[] {
    return articles.toArray();
}

public function findArticleById(int id) returns models:Article? {
    return articles[id];
}

public function createArticle(models:CreateArticleRequest payload) returns models:Article {
    int newId = articles.length() + 1;
    models:Article article = {
        id: newId,
        title: payload.title,
        content: payload.content,
        status: "draft"
    };
    articles.add(article);
    return article;
}

public function updateArticle(int id, models:UpdateArticleRequest payload) returns models:Article? {
    models:Article? existingArticle = articles[id];

    if existingArticle is () {
        return ();
    }

    models:Article updatedArticle = {
        id,
        title: payload.title,
        content: payload.content,
        status: payload.status
    };
    articles.put(updatedArticle);
    return updatedArticle;
}

public function deleteArticle(int id) returns boolean {
    models:Article? existingArticle = articles[id];

    if existingArticle is () {
        return false;
    }

    _ = articles.remove(id);
    return true;
}
```

Penjelasan:

1. Repository menyimpan semua logic akses data.
2. Untuk tahap awal, data bisa memakai `table` di memory.
3. Saat sudah memakai database, fungsi seperti `findAllArticles` dan
   `createArticle` bisa diganti dengan query database tanpa mengubah resource
   API secara besar-besaran.

## 3. Tambahkan Service

Tambahkan business logic pada `modules/services/services.bal`.

Contoh:

```ballerina
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.repositories;

public function getArticles() returns models:Article[] {
    return repositories:findAllArticles();
}

public function getArticleById(int id) returns models:Article? {
    return repositories:findArticleById(id);
}

public function createArticle(models:CreateArticleRequest payload) returns models:Article|error {
    if payload.title.trim().length() == 0 {
        return error("Title is required");
    }

    if payload.content.trim().length() == 0 {
        return error("Content is required");
    }

    return repositories:createArticle(payload);
}

public function updateArticle(int id, models:UpdateArticleRequest payload) returns models:Article?|error {
    if id <= 0 {
        return error("Invalid article ID");
    }

    if payload.title.trim().length() == 0 {
        return error("Title is required");
    }

    return repositories:updateArticle(id, payload);
}

public function deleteArticle(int id) returns boolean {
    return repositories:deleteArticle(id);
}
```

Penjelasan:

1. Service menjadi tempat validasi dan aturan bisnis.
2. Resource HTTP tidak perlu tahu detail penyimpanan data.
3. Jika validasi gagal, service bisa mengembalikan `error`.
4. Jika data tidak ditemukan, service bisa mengembalikan `()`.

## 4. Tambahkan HTTP Resource

Ubah `main.bal` agar menjalankan HTTP listener dan mendefinisikan REST API.

Contoh:

```ballerina
import ballerina/http;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.services;

listener http:Listener apiListener = new (8080);

service /api/v1/articles on apiListener {
    resource function get .() returns models:Article[] {
        return services:getArticles();
    }

    resource function get [int id]() returns models:Article|http:NotFound {
        models:Article? article = services:getArticleById(id);

        if article is () {
            return {
                body: {
                    code: "NOT_FOUND",
                    message: "Article not found"
                }
            };
        }

        return article;
    }

    resource function post .(@http:Payload models:CreateArticleRequest payload)
            returns http:Created|http:BadRequest {
        models:Article|error result = services:createArticle(payload);

        if result is error {
            return {
                body: {
                    code: "VALIDATION_ERROR",
                    message: result.message()
                }
            };
        }

        return {
            body: result
        };
    }

    resource function put [int id](@http:Payload models:UpdateArticleRequest payload)
            returns models:Article|http:BadRequest|http:NotFound {
        models:Article?|error result = services:updateArticle(id, payload);

        if result is error {
            return {
                body: {
                    code: "VALIDATION_ERROR",
                    message: result.message()
                }
            };
        }

        if result is () {
            return {
                body: {
                    code: "NOT_FOUND",
                    message: "Article not found"
                }
            };
        }

        return result;
    }

    resource function delete [int id]() returns http:NoContent|http:NotFound {
        boolean deleted = services:deleteArticle(id);

        if !deleted {
            return {
                body: {
                    code: "NOT_FOUND",
                    message: "Article not found"
                }
            };
        }

        return {};
    }
}
```

Penjelasan resource:

| Resource | Penjelasan |
| --- | --- |
| `resource function get .()` | Mewakili `GET /api/v1/articles`. |
| `resource function get [int id]()` | Mewakili `GET /api/v1/articles/{id}`. |
| `@http:Payload` | Mengambil JSON request body dan mengubahnya ke record Ballerina. |
| `http:Created` | Response HTTP `201 Created`. |
| `http:BadRequest` | Response HTTP `400 Bad Request`. |
| `http:NotFound` | Response HTTP `404 Not Found`. |
| `http:NoContent` | Response HTTP `204 No Content`. |

### Penanganan Error dengan try/catch Pattern

Di Ballerina, pola seperti `try/catch` ditulis menggunakan `do { ... } on fail
error err { ... }`. Gunakan pola ini pada resource function untuk menangkap
error dari service, repository, database, atau proses lain yang memakai `check`
atau `fail`.

Contoh:

```ballerina
import ballerina/http;
import ballerina/log;
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.services;

service /api/v1/articles on apiListener {
    resource function get .() returns http:Ok|http:InternalServerError {
        do {
            models:Article[]|error result = services:getArticles();
            models:Article[] articles = check result;

            http:Ok response = {
                body: successResponse(articles, "Daftar artikel berhasil diambil")
            };
            return response;
        } on fail error err {
            log:printError("Failed to get articles", err);

            http:InternalServerError response = {
                body: errorResponse(
                    "INTERNAL_ERROR",
                    "Terjadi kesalahan pada server, silakan coba lagi nanti"
                )
            };
            return response;
        }
    }

    resource function post .(@http:Payload models:CreateArticleRequest payload)
            returns http:Created|http:BadRequest|http:InternalServerError {
        do {
            models:Article|error result = services:createArticle(payload);
            models:Article article = check result;

            http:Created response = {
                body: successResponse(article, "Artikel berhasil dibuat")
            };
            return response;
        } on fail error err {
            if err.message() == "Title is required" || err.message() == "Content is required" {
                http:BadRequest response = {
                    body: errorResponse("VALIDATION_ERROR", err.message())
                };
                return response;
            }

            log:printError("Failed to create article", err);

            http:InternalServerError response = {
                body: errorResponse(
                    "INTERNAL_ERROR",
                    "Terjadi kesalahan pada server, silakan coba lagi nanti"
                )
            };
            return response;
        }
    }
}
```

Catatan penting:

1. Gunakan `check` pada pemanggilan function yang bisa mengembalikan `error`.
2. Tangani validation error menjadi `400` dengan `VALIDATION_ERROR`.
3. Tangani data tidak ditemukan menjadi `404` dengan `NOT_FOUND`.
4. Tangani error tidak terduga menjadi `500` dengan `INTERNAL_ERROR`.
5. Log detail error di server, tetapi jangan expose stack trace atau pesan error
   internal ke client.

## 5. API Response Standard

Standar response lengkap dijelaskan di
[API-Response-Standard.md](API-Response-Standard.md). Semua endpoint REST API di
project ini sebaiknya memakai struktur response yang sama, baik untuk response
sukses maupun error.

Struktur response utama:

| Field | Tipe | Keterangan |
| --- | --- | --- |
| `success` | `boolean` | `true` jika request berhasil, `false` jika gagal. |
| `message` | `string` | Pesan yang mudah dibaca oleh user atau frontend. |
| `data` | `anydata \| null` | Payload hasil request. Bernilai `null` saat error. |
| `errors` | `ErrorDetail \| null` | Detail error. Bernilai `null` saat sukses. |
| `meta` | `object` | Metadata tambahan seperti `timestamp`, `requestId`, dan `pagination`. |

Definisi tipe yang disarankan di `modules/models/models.bal` atau module helper
response:

```ballerina
import ballerina/time;

public type ApiResponse record {|
    boolean success;
    string message;
    anydata data?;
    ErrorDetail? errors = ();
    ResponseMeta meta?;
|};

public type ErrorDetail record {|
    string code;
    string message;
    anydata details?;
|};

public type ResponseMeta record {|
    string timestamp = time:utcToString(time:utcNow());
    string? requestId?;
    Pagination? pagination?;
|};

public type Pagination record {|
    int page;
    int 'limit;
    int totalItems;
    int totalPages;
|};
```

Helper response yang disarankan:

```ballerina
public function successResponse(anydata data, string message = "Success",
        Pagination? pagination = ()) returns ApiResponse {
    return {
        success: true,
        message: message,
        data: data,
        errors: (),
        meta: {pagination: pagination}
    };
}

public function errorResponse(string code, string message, anydata? details = ())
        returns ApiResponse {
    return {
        success: false,
        message: message,
        data: (),
        errors: {code: code, message: message, details: details}
    };
}
```

Contoh response sukses:

```json
{
  "success": true,
  "message": "Artikel berhasil diambil",
  "data": {
    "id": 1,
    "title": "Artikel Pertama",
    "content": "Konten artikel pertama",
    "status": "published"
  },
  "errors": null,
  "meta": {
    "timestamp": "2026-07-02T09:15:32Z",
    "requestId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  }
}
```

Contoh response list dengan pagination:

```json
{
  "success": true,
  "message": "Daftar artikel berhasil diambil",
  "data": [
    { "id": 1, "title": "Artikel Pertama", "status": "published" },
    { "id": 2, "title": "Artikel Kedua", "status": "draft" }
  ],
  "errors": null,
  "meta": {
    "timestamp": "2026-07-02T09:22:01Z",
    "pagination": {
      "page": 1,
      "limit": 10,
      "totalItems": 27,
      "totalPages": 3
    }
  }
}
```

Contoh response error:

```json
{
  "success": false,
  "message": "Artikel tidak ditemukan",
  "data": null,
  "errors": {
    "code": "NOT_FOUND",
    "message": "Artikel dengan id 999 tidak ditemukan",
    "details": null
  },
  "meta": {
    "timestamp": "2026-07-02T09:31:20Z"
  }
}
```

Mapping HTTP status dan error code:

| Situasi | HTTP Status | `errors.code` |
| --- | --- | --- |
| Sukses ambil data | `200` | - |
| Sukses buat data | `201` | - |
| Validasi input gagal | `400` | `VALIDATION_ERROR` |
| Tidak terautentikasi | `401` | `UNAUTHORIZED` |
| Tidak punya akses | `403` | `FORBIDDEN` |
| Resource tidak ditemukan | `404` | `NOT_FOUND` |
| Konflik data atau duplikat | `409` | `CONFLICT` |
| Error tak terduga di server | `500` | `INTERNAL_ERROR` |

Gunakan `SCREAMING_SNAKE_CASE` untuk `errors.code` agar mudah diproses oleh
frontend dan mudah dipantau melalui API gateway atau monitoring.

## 6. Testing API dengan curl

Ambil semua artikel:

```bash
curl http://localhost:8080/api/v1/articles
```

Ambil artikel berdasarkan ID:

```bash
curl http://localhost:8080/api/v1/articles/1
```

Buat artikel:

```bash
curl -X POST http://localhost:8080/api/v1/articles \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Judul Baru\",\"content\":\"Konten artikel baru\"}"
```

Ubah artikel:

```bash
curl -X PUT http://localhost:8080/api/v1/articles/1 \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Judul Update\",\"content\":\"Konten update\",\"status\":\"published\"}"
```

Hapus artikel:

```bash
curl -X DELETE http://localhost:8080/api/v1/articles/1
```

## 7. Menulis Unit Test

Test untuk service bisa diletakkan di `modules/services/tests/services_test.bal`.

Contoh:

```ballerina
import ballerina/test;
import rayha/swamedia_portal_be.models;

@test:Config {}
function testCreateArticle() {
    models:CreateArticleRequest payload = {
        title: "Artikel Test",
        content: "Konten test"
    };

    models:Article|error result = createArticle(payload);

    test:assertFalse(result is error);

    if result is models:Article {
        test:assertEquals(result.title, "Artikel Test");
        test:assertEquals(result.status, "draft");
    }
}

@test:Config {}
function testCreateArticleWithEmptyTitle() {
    models:CreateArticleRequest payload = {
        title: "",
        content: "Konten test"
    };

    models:Article|error result = createArticle(payload);

    test:assertTrue(result is error);
}
```

Jalankan test:

```bash
bal test
```

## 8. Konfigurasi

Nilai konfigurasi sebaiknya diletakkan pada module `config`.

Contoh `modules/config/config.bal`:

```ballerina
public configurable int port = 8080;
public configurable string apiBasePath = "/api/v1";
```

Lalu di `main.bal`:

```ballerina
import ballerina/http;
import rayha/swamedia_portal_be.config;

listener http:Listener apiListener = new (config:port);
```

Konfigurasi bisa dikirim dari environment variable atau file konfigurasi
Ballerina sesuai kebutuhan deployment.

## 8a. Redis (cache untuk business process mendatang)

Project ini sudah terpasang `ballerinax/redis` sebagai cache generik yang bisa dipakai
modul mana pun untuk kebutuhan bisnis proses mendatang (rate limiting, session data,
caching hasil lookup yang mahal, dsb).

Lokasi kode: `modules/repositories/cache.bal`, tiga fungsi publik:

```ballerina
repositories:cacheSet(key, value, ttlSeconds = 0)   // simpan (JSON), ttlSeconds = 0 berarti tanpa expiry
repositories:cacheGet(key)                          // baca; hasilnya () kalau cache miss
repositories:cacheDelete(...keys)                    // hapus satu atau lebih key
```

Koneksi ke Redis bersifat **lazy** — baru benar-benar connect saat fungsi cache pertama
kali dipanggil, bukan saat module di-load. Ini supaya `bal build`/`bal test` tidak pernah
butuh Redis menyala. Hanya `bal run` (atau test yang benar-benar memanggil fungsi cache)
yang butuh Redis aktif.

Konfigurasi ada di `modules/config/config.bal`: `redisHost`, `redisPort`,
`redisPassword`, `redisDatabase`, `redisConnectionTimeoutSeconds`. Default-nya sudah
cocok dengan `docker-compose.yml` di root project.

Jalankan Redis untuk development lokal:

```bash
docker compose up -d
```

Contoh pemakaian (cache-aside) ada di `services:userInfo()` — cache dianggap
"nice-to-have", jadi kalau Redis mati, request tetap jalan normal (fallback langsung ke
WSO2 IS), hanya saja tanpa manfaat cache-nya. Kegagalan baca/tulis cache di-log tapi
tidak membuat request gagal.

## 9. Best Practice di Project Ini

Gunakan pola berikut saat menambah API baru:

1. Definisikan request dan response model di `modules/models`.
2. Buat fungsi akses data di `modules/repositories`.
3. Buat business logic dan validasi di `modules/services`.
4. Buat HTTP resource di `main.bal`.
5. Tambahkan test untuk logic penting.
6. Jalankan `bal test` dan `bal build`.

Hal yang sebaiknya dihindari:

1. Menaruh semua logic di `main.bal`.
2. Mengakses database langsung dari HTTP resource.
3. Mengembalikan format error yang berbeda-beda antar endpoint.
4. Menggunakan tipe data `json` untuk semua hal jika struktur datanya sudah
   jelas. Lebih baik gunakan `record`.
5. Membiarkan validasi tersebar di banyak tempat tanpa pola yang konsisten.

## 10. Contoh Naming Endpoint

Gunakan kata benda jamak untuk resource:

| Resource | Endpoint yang disarankan |
| --- | --- |
| Article | `/api/v1/articles` |
| User | `/api/v1/users` |
| Category | `/api/v1/categories` |
| Comment | `/api/v1/comments` |

Gunakan HTTP method sesuai aksi:

| Aksi | Method | Contoh |
| --- | --- | --- |
| List data | `GET` | `GET /api/v1/articles` |
| Detail data | `GET` | `GET /api/v1/articles/1` |
| Buat data | `POST` | `POST /api/v1/articles` |
| Ubah semua field utama | `PUT` | `PUT /api/v1/articles/1` |
| Ubah sebagian field | `PATCH` | `PATCH /api/v1/articles/1` |
| Hapus data | `DELETE` | `DELETE /api/v1/articles/1` |

## 11. Checklist Menambah Endpoint Baru

Sebelum endpoint dianggap selesai:

```text
[ ] Model request sudah dibuat.
[ ] Model response sudah dibuat.
[ ] Service sudah berisi validasi utama.
[ ] Repository sudah memisahkan logic akses data.
[ ] Resource HTTP sudah mengembalikan status code yang tepat.
[ ] Response error memakai format konsisten.
[ ] Test sukses dijalankan dengan `bal test`.
[ ] Project sukses di-build dengan `bal build`.
```

## 12. Troubleshooting

### Port sudah digunakan

Jika `bal run` gagal karena port sudah dipakai, ubah port listener di
`main.bal` atau jadikan port sebagai configurable value di module `config`.

### Request body tidak terbaca

Pastikan request memakai header:

```text
Content-Type: application/json
```

Pastikan juga bentuk JSON sesuai dengan record request yang didefinisikan di
`modules/models`.

### Import module gagal

Pastikan nama import mengikuti format:

```ballerina
import rayha/swamedia_portal_be.models;
import rayha/swamedia_portal_be.services;
import rayha/swamedia_portal_be.repositories;
```

Format import berasal dari `org` dan `name` di `Ballerina.toml`.

## Ringkasan Alur Pembuatan API

Urutan paling aman saat membuat RESTful API baru:

```text
models -> repositories -> services -> main.bal -> tests -> bal build
```

Dengan pola ini, API lebih mudah dikembangkan, dites, dan dirawat ketika jumlah
endpoint bertambah.
