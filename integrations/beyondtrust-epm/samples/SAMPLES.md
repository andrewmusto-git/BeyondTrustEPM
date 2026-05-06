# Sample Data for BeyondTrust EPM → Veza OAA Integration

This directory holds representative sample data used for **local dry-run testing** of the integration script.

No sample data is required for this connector because it reads directly from the BeyondTrust PM Cloud REST API. However, you may place captured API responses here for offline testing.

---

## What to place here (optional, for dry-run testing)

If you want to run a fully offline dry-run without hitting the live API, you can capture live API responses and save them here. The current integration script reads from the live API, so no sample files are strictly required.

For future offline/mock testing, you would save files such as:

### `users.json`
A JSON array of user objects from `GET /management-api/v1/Users` (the `data` array from the paged response).

Example structure:
```json
[
  {
    "id": "a1b2c3d4-0000-0000-0000-000000000001",
    "accountName": "john.doe@company.com",
    "emailAddress": "john.doe@company.com",
    "created": "2023-01-15T10:00:00Z",
    "lastSignedIn": "2024-05-01T08:30:00Z",
    "disabled": false,
    "roles": [
      { "id": "r0000001-0000-0000-0000-000000000001", "name": "Administrator" }
    ]
  }
]
```

### `roles.json`
A JSON array from `GET /management-api/v1/Roles`.

Example structure:
```json
[
  {
    "id": "r0000001-0000-0000-0000-000000000001",
    "name": "Administrator",
    "allowPermissions": [
      { "resource": "*", "action": "admin" }
    ]
  },
  {
    "id": "r0000001-0000-0000-0000-000000000002",
    "name": "Auditor",
    "allowPermissions": [
      { "resource": "*", "action": "read" }
    ]
  }
]
```

### `groups.json`
A JSON array from `GET /management-api/v1/Groups` (the `data` array).

### `policies.json`
A JSON array from `GET /management-api/v1/Policies` (the `data` array).

---

## How to capture live data

```bash
# Get a token first
TOKEN=$(curl -s -X POST https://your-tenant.pm.beyondtrustcloud.com/oauth/connect/token \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=YOUR_CLIENT_ID" \
  --data-urlencode "client_secret=YOUR_CLIENT_SECRET" \
  --data-urlencode "scope=urn:management:api" | jq -r .access_token)

# Capture users
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://your-tenant.pm.beyondtrustcloud.com/management-api/v1/Users?Pagination.PageSize=200&Pagination.PageNumber=1" \
  | jq .data > samples/users.json

# Capture roles
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://your-tenant.pm.beyondtrustcloud.com/management-api/v1/Roles" \
  > samples/roles.json

# Capture groups
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://your-tenant.pm.beyondtrustcloud.com/management-api/v1/Groups?Pagination.PageSize=200&Pagination.PageNumber=1" \
  | jq .data > samples/groups.json

# Capture policies
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://your-tenant.pm.beyondtrustcloud.com/management-api/v1/Policies?Pagination.PageSize=200&Pagination.PageNumber=1" \
  | jq .data > samples/policies.json
```
