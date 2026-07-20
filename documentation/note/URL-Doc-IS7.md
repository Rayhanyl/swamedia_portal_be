# WSO2 Identity Server 7.1.0 — SCIM2 User Management API

## Referensi
- Dokumentasi resmi: https://is.docs.wso2.com/en/7.1.0/
- SCIM2 Users REST API: https://is.docs.wso2.com/en/7.1.0/apis/scim2/scim2-users-rest-api/#tag/Users-Endpoint/operation/getUsersByPost

**Base URL:** `https://iam.apicentrum.biz.id/scim2`
**Auth:** Basic Auth (Super Admin IS) — berlaku untuk semua endpoint di bawah

---

## 1. List User

`GET /scim2/Users`

### Query Params

| Param | Contoh Nilai |
|---|---|
| `count` | `11` |
| `domain` | `PRIMARY` |
| `startIndex` | `1` |
| `filter` | `userName+co+finance` |

### Contoh Response

```json
{
  "totalResults": 3,
  "startIndex": 1,
  "itemsPerPage": 3,
  "schemas": [
    "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  ],
  "Resources": [
    {
      "emails": ["example@yopmail.com"],
      "urn:scim:schemas:extension:custom:User": {
        "loccanaActorUserId": "18",
        "loccanaEffectiveRoleId": "124",
        "loccanaCompanyId": "1",
        "loccanaAllowedRegionIds": "[4]",
        "loccanaDefaultRegionId": "4",
        "forcePasswordReset": "true",
        "loccanaLegacyLoginId": "69",
        "loccanaLegacyRoleId": "124",
        "loccanaAccessStatus": "1",
        "loccanaLegacyImage": "03b2a26abbc789a31f0c4172f23a206b.png"
      },
      "addresses": [
        { "formatted": "endira alda", "type": "work" }
      ],
      "meta": {
        "created": "2026-04-28T11:55:32.331622017Z",
        "location": "https://iam.apicentrum.biz.id/scim2/Users/cb7fffef-f840-419e-837d-2605a6d9d10c",
        "lastModified": "2026-07-14T03:52:52.451321Z",
        "resourceType": "User"
      },
      "displayName": "finance",
      "roles": [
        {
          "audienceValue": "d8bc4e4d-759c-4f75-adc5-a0ac738a09cb",
          "display": "finance",
          "audienceType": "application",
          "value": "56ea62a7-61e0-47db-965c-dbdaf11ae661",
          "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/56ea62a7-61e0-47db-965c-dbdaf11ae661",
          "audienceDisplay": "loccana"
        },
        {
          "audienceValue": "10084a8d-113f-4211-a0d5-efe36b082211",
          "display": "everyone",
          "audienceType": "organization",
          "value": "e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
          "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
          "audienceDisplay": "Super"
        }
      ],
      "name": {
        "formatted": "finance",
        "givenName": "finance"
      },
      "active": true,
      "id": "cb7fffef-f840-419e-837d-2605a6d9d10c",
      "userName": "finance",
      "urn:scim:wso2:schema": {
        "emailAddresses": ["example@yopmail.com"],
        "emailOTPDisabled": false,
        "forcePasswordReset": true
      },
      "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User": {
        "organization": "PT Endira Alda"
      }
    },
    {
      "emails": ["qa-finance@yopmail.com"],
      "urn:scim:schemas:extension:custom:User": {
        "loccanaActorUserId": "39",
        "loccanaEffectiveRoleId": "124",
        "loccanaCompanyId": "1",
        "loccanaAllowedRegionIds": "[4]",
        "loccanaDefaultRegionId": "4",
        "loccanaLegacyLoginId": "89",
        "loccanaLegacyRoleId": "124"
      },
      "meta": {
        "created": "2026-04-30T10:10:43.307584526Z",
        "location": "https://iam.apicentrum.biz.id/scim2/Users/161ab4ab-061d-4c9d-a000-db6569bb5abf",
        "lastModified": "2026-05-20T18:56:50.011688Z",
        "resourceType": "User"
      },
      "roles": [
        {
          "audienceValue": "d8bc4e4d-759c-4f75-adc5-a0ac738a09cb",
          "display": "finance",
          "audienceType": "application",
          "value": "56ea62a7-61e0-47db-965c-dbdaf11ae661",
          "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/56ea62a7-61e0-47db-965c-dbdaf11ae661",
          "audienceDisplay": "loccana"
        },
        {
          "audienceValue": "10084a8d-113f-4211-a0d5-efe36b082211",
          "display": "everyone",
          "audienceType": "organization",
          "value": "e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
          "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
          "audienceDisplay": "Super"
        }
      ],
      "name": {
        "givenName": "QA finance"
      },
      "active": true,
      "id": "161ab4ab-061d-4c9d-a000-db6569bb5abf",
      "userName": "qa_finance"
    },
    {
      "emails": ["swaportal_finance@yopmail.com"],
      "urn:scim:schemas:extension:custom:User": {
        "swaportal_role_id": "5",
        "swaportal_group_id": "swamedia_portal_app"
      },
      "meta": {
        "created": "2026-07-16T04:56:31.656679Z",
        "location": "https://iam.apicentrum.biz.id/scim2/Users/c81997b0-066b-432c-b385-59e9f8edb46e",
        "lastModified": "2026-07-19T02:36:53.026810Z",
        "resourceType": "User"
      },
      "roles": [
        {
          "audienceValue": "608c97b7-22f6-4554-9984-0b0f3caa3bd3",
          "display": "Finance",
          "audienceType": "application",
          "value": "8f758a3f-5fe8-473d-9b81-9259f97c5ce9",
          "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/8f758a3f-5fe8-473d-9b81-9259f97c5ce9",
          "audienceDisplay": "Swamedia Portal"
        },
        {
          "audienceValue": "10084a8d-113f-4211-a0d5-efe36b082211",
          "display": "everyone",
          "audienceType": "organization",
          "value": "e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
          "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
          "audienceDisplay": "Super"
        }
      ],
      "name": {
        "givenName": "Finance",
        "familyName": "Swamedia Portal"
      },
      "groups": [
        {
          "display": "user_portal_swamedia",
          "value": "f886de8b-eb34-4528-9ea4-6d422864b30e",
          "$ref": "https://iam.apicentrum.biz.id/scim2/Groups/f886de8b-eb34-4528-9ea4-6d422864b30e"
        }
      ],
      "id": "c81997b0-066b-432c-b385-59e9f8edb46e",
      "userName": "swaportal_finance",
      "urn:scim:wso2:schema": {
        "emailAddresses": ["swaportal_finance@yopmail.com"],
        "emailOTPDisabled": false
      },
      "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User": {
        "organization": "PT Swamedia Informatika"
      }
    }
  ]
}
```

---

## 2. Detail Data User

`GET /scim2/Users/{id}`

**Contoh:** `/scim2/Users/c81997b0-066b-432c-b385-59e9f8edb46e`

### Contoh Response

```json
{
  "emails": ["swaportal_finance@yopmail.com"],
  "urn:scim:schemas:extension:custom:User": {
    "swaportal_role_id": "5",
    "swaportal_group_id": "swamedia_portal_app"
  },
  "meta": {
    "created": "2026-07-16T04:56:31.656679Z",
    "location": "https://iam.apicentrum.biz.id/scim2/Users/c81997b0-066b-432c-b385-59e9f8edb46e",
    "lastModified": "2026-07-17T04:12:04.652682Z",
    "resourceType": "User"
  },
  "schemas": [
    "urn:ietf:params:scim:schemas:core:2.0:User",
    "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User",
    "urn:scim:wso2:schema",
    "urn:scim:schemas:extension:custom:User"
  ],
  "roles": [
    {
      "audienceValue": "608c97b7-22f6-4554-9984-0b0f3caa3bd3",
      "display": "Finance",
      "audienceType": "application",
      "value": "8f758a3f-5fe8-473d-9b81-9259f97c5ce9",
      "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/8f758a3f-5fe8-473d-9b81-9259f97c5ce9",
      "audienceDisplay": "Swamedia Portal"
    },
    {
      "audienceValue": "10084a8d-113f-4211-a0d5-efe36b082211",
      "display": "everyone",
      "audienceType": "organization",
      "value": "e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
      "$ref": "https://iam.apicentrum.biz.id/scim2/v2/Roles/e8a7cfcb-3e4e-4f46-bc0e-aae22f3bc98e",
      "audienceDisplay": "Super"
    }
  ],
  "name": {
    "givenName": "finance",
    "familyName": "swamedia portal"
  },
  "groups": [
    {
      "display": "user_portal_swamedia",
      "value": "f886de8b-eb34-4528-9ea4-6d422864b30e",
      "$ref": "https://iam.apicentrum.biz.id/scim2/Groups/f886de8b-eb34-4528-9ea4-6d422864b30e"
    }
  ],
  "id": "c81997b0-066b-432c-b385-59e9f8edb46e",
  "userName": "swaportal_finance",
  "urn:scim:wso2:schema": {
    "emailAddresses": ["swaportal_finance@yopmail.com"],
    "emailOTPDisabled": false
  },
  "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User": {
    "organization": "PT Swamedia Informatika"
  }
}
```

---

## 3. Update Data User

`PATCH /scim2/Users/{id}`

**Contoh:** `/scim2/Users/c81997b0-066b-432c-b385-59e9f8edb46e`

### Payload

```json
{
  "Operations": [
    { "op": "replace", "value": { "userName": "swaportal_finance" } },
    { "op": "replace", "value": { "name": { "givenName": "Finance" } } },
    { "op": "replace", "value": { "name": { "familyName": "Swamedia Portal" } } },
    {
      "op": "replace",
      "value": {
        "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User": {
          "organization": "PT Swamedia Informatika"
        }
      }
    },
    {
      "op": "replace",
      "value": { "urn:scim:wso2:schema": { "country": "" } }
    },
    { "op": "replace", "value": { "emails": ["swaportal_finance@yopmail.com"] } },
    { "op": "replace", "value": { "phoneNumbers": [] } },
    {
      "op": "replace",
      "value": {
        "urn:scim:wso2:schema": {
          "emailAddresses": ["swaportal_finance@yopmail.com"]
        }
      }
    },
    {
      "op": "replace",
      "value": { "urn:scim:wso2:schema": { "mobileNumbers": [] } }
    },
    { "op": "add", "value": { "addresses": [] } },
    {
      "op": "replace",
      "value": { "urn:scim:wso2:schema": { "emailOTPDisabled": false } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:wso2:schema": { "failedLoginAttemptsBeforeSuccess": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:wso2:schema": { "totpEnabled": "" } }
    },
    {
      "op": "replace",
      "value": {
        "urn:scim:schemas:extension:custom:User": { "swaportal_role_id": "5" }
      }
    },
    {
      "op": "replace",
      "value": {
        "urn:scim:schemas:extension:custom:User": { "swaportal_group_id": "swamedia_portal_app" }
      }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "full_name": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "NIP": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "company": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaActorUserId": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaLegacyLoginId": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaLegacyRoleId": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaEffectiveRoleId": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaCompanyId": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaDefaultRegionId": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaAllowedRegionIds": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaBirthPlace": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaReligion": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaAccessStatus": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaLegacyImage": "" } }
    },
    {
      "op": "replace",
      "value": { "urn:scim:schemas:extension:custom:User": { "loccanaRawPhone": "" } }
    }
  ],
  "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"]
}
```

> **Catatan:** payload asli berisi beberapa operasi `{ "op": "replace", "value": {} }` kosong (kemungkinan artefak dari tool/UI yang generate request). Sudah dihapus dari versi rapi ini karena tidak membawa data.

---

## 4. Update Password

`PATCH /scim2/Users/{id}`

**Contoh:** `/scim2/Users/c81997b0-066b-432c-b385-59e9f8edb46e`

### Payload

```json
{
  "Operations": [
    {
      "op": "replace",
      "value": { "password": "Admin123456!" }
    }
  ],
  "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"]
}
```

> ⚠️ Password di atas hanya contoh/dummy dari dokumentasi ini — pastikan tidak dipakai sebagai password produksi.