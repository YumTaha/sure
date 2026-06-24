# Sophtron v1 integration expansion (full history, re-auth, holdings, rewards)

**Date:** 2026-06-24
**Branch:** `feat/sophtron-v1-expansion`
**Status:** Phase 1 SHIPPED (PR #8, merged to main as `6f2ac75a`); Phases 2-4 pending.

---

## Background

Sure uses Sophtron's v1 (legacy) API. Shipped to date:

- Transactions race-fix: deduplicated concurrent sync jobs.
- Connection de-dup (reuse-on-reconnect): `refresh_user_institution` reuses an existing `UserInstitution` instead of minting a new one; `delete_user_institution` tears down the Sophtron record on disconnect.

This plan adds 4 capabilities from the full v1 endpoint set, confirmed against `legacy.md`. Stay on v1 — no v2 migration.

---

## Endpoints in scope

All endpoints are `POST` against `https://api.sophtron.com/`. Request/response shapes confirmed from `legacy.md` (legacy endpoint reference doc).

### 1. Full transaction history — Create and Refresh

**`POST /api/UserInstitution/CreateUserInstitutionWithFullHistory`**

Request body (from legacy.md §18):
```json
{
  "aggregate": true,
  "identity": false,
  "verification": false,
  "balance": false,
  "rewards": false,
  "history": true,
  "userID": "<sophtron-user-id>",
  "institutionID": "<institution-id>",
  "userName": "<credential-username>",
  "password": "<credential-password>",
  "pin": "",
  "companyID": ""
}
```
> Note: legacy.md shows the flags as `false` in the schema example (field defaults). In production use, pass `history: true` and `aggregate: true` to trigger full history retrieval — these are the flags that distinguish this endpoint's behaviour from plain `CreateUserInstitution`.

Response (200):
```json
{
  "jobID": "<job-id>",
  "userInstitutionID": "<user-institution-id>",
  "memberID": "<member-id>"
}
```

---

**`POST /api/UserInstitution/RefreshUserInstitutionFullHistory`**

Request body (from legacy.md §21):
```json
{
  "aggregate": true,
  "identity": false,
  "verification": false,
  "balance": false,
  "rewards": false,
  "history": true,
  "userInstitutionID": "<user-institution-id>"
}
```

Response (200):
```json
{
  "jobID": "<job-id>",
  "userInstitutionID": "<user-institution-id>",
  "memberID": "<member-id>"
}
```

---

### 2. Re-auth / retry

**`POST /api/userinstitution/RetryAddingUserInstitution`**

Request body (from legacy.md §33):
```json
{
  "userInstitutionID": "<user-institution-id>"
}
```

Response (200):
```json
{
  "jobID": "<job-id>",
  "userInstitutionID": "<user-institution-id>",
  "memberID": "<member-id>"
}
```

> Note: there is also a `RetryAddingUserInstitutionWithRewardsInfo` variant (legacy.md §32) with the same single-field body. That variant is out of scope for Phase 2 but is available if rewards + re-auth need to be combined.

---

### 3. Holdings

**`POST /api/holdings/GetHoldingsByAccountId`**

Request body (from legacy.md §2):
```json
{
  "accountID": "<sophtron-account-id>"
}
```

Response (200) — array of holding records:
```json
[
  {
    "userID": "<user-id>",
    "id": "<record-id>",
    "createdDateUtc": "1970-01-01T00:00:00.000Z",
    "lastModifiedUtc": "1970-01-01T00:00:00.000Z",
    "accountID": "<account-id>",
    "holdingID": "<holding-id>",
    "userInstitutionAccountID": "<ui-account-id>",
    "symbol": "<ticker>",
    "quantity": 0,
    "lastUpdateDate": "1970-01-01T00:00:00.000Z",
    "currentValue": 0,
    "costBasis": 0,
    "lastPrice": 0,
    "todaysGL": 0,
    "totalGL": 0,
    "description": "<security-description>"
  }
]
```

---

### 4. Rewards — Refresh and Create

**`POST /api/UserInstitution/RefreshUserInstitutionWithRewardsInfo`**

Request body (from legacy.md §25):
```json
{
  "aggregate": false,
  "identity": false,
  "verification": false,
  "balance": false,
  "rewards": true,
  "history": false,
  "userInstitutionID": "<user-institution-id>"
}
```
> Note: legacy.md shows flags as `false` defaults. Pass `rewards: true` to trigger rewards retrieval.

Response (200):
```json
{
  "jobID": "<job-id>",
  "userInstitutionID": "<user-institution-id>",
  "memberID": "<member-id>"
}
```

---

**`POST /api/UserInstitution/CreateUserInstitutionWithRewardsInfo`**

Request body (from legacy.md §26):
```json
{
  "aggregate": false,
  "identity": false,
  "verification": false,
  "balance": false,
  "rewards": true,
  "history": false,
  "userID": "<sophtron-user-id>",
  "institutionID": "<institution-id>",
  "userName": "<credential-username>",
  "password": "<credential-password>",
  "pin": "",
  "companyID": ""
}
```

Response (200):
```json
{
  "jobID": "<job-id>",
  "userInstitutionID": "<user-institution-id>",
  "memberID": "<member-id>"
}
```

---

## Why each capability

**Full history:** Fixes a completeness/cold-start gap. The current `CreateUserInstitution` call only pulls recent transactions; the older rows within the current billing cycle (and all prior history) are missed on a fresh connect. `CreateUserInstitutionWithFullHistory` is the correct v1 fix — it signals Sophtron to pull complete history via `history: true` + `aggregate: true`.

**Re-auth / retry:** Closes the known de-dup limitation from the shipped reconnect branch. When a connection's credentials have changed or expired, the current path (plain `refresh_user_institution`) sends stale credentials or creates a new UID. `RetryAddingUserInstitution` retries authentication on the SAME `userInstitutionID`, preserving de-dup without minting a new UID.

**Holdings:** Sure has a complete investment account model (Holdings, Securities, Trades) but the Sophtron importer only populates transactions and balance. Investment accounts added via Sophtron display a balance with no holdings breakdown. `GetHoldingsByAccountId` fills that gap per-account.

**Rewards:** Nice-to-have — exposes credit-card rewards/points balances (e.g. Discover cashback). Rewards data is already present in `GetUserInstitutionAccounts` response under `creditCardData.rewardBalance` / `rewardUnit` / `rewardDescription`; the `WithRewardsInfo` variants ensure Sophtron fetches the most current rewards value during the sync job.

---

## Phased implementation plan

Each phase ships as its own branch + PR + Copilot review before the next phase begins. The "one PR for all phases vs PR-per-phase" decision was resolved as **PR-per-phase** — Phase 1 shipped as its own PR #8.

### Phase 1 — Full transaction history (highest value; foundational) ✅ SHIPPED

**Shipped:** PR #8, merge commit `6f2ac75a`, feature commit `ee49c450`.

**Goal:** Replace the plain create/refresh calls with their full-history equivalents so both initial connect and every subsequent reconnect pull complete transaction history.

**What shipped:**
- Added `create_user_institution_with_full_history` and `refresh_user_institution_full_history` to `app/models/provider/sophtron.rb`.
- `connect_institution` now calls the full-history create for new connections; the de-dup reuse path (reconnect) still calls `refresh_user_institution` with the preserved UID — this is intentional (reconnect reuses the existing `UserInstitution`, so no full-history create is needed there).
- Initial transaction fetch window widened from 120 days to 3 years.

**Tests:** Minitest with mocked provider; correct endpoint verified on create vs. reconnect paths. No DB migration required.

---

### Phase 2 — Re-auth / retry

**Goal:** Close the de-dup re-auth limitation. When an existing `SophtronItem` is in `status: requires_update` (broken/expired credentials), use `RetryAddingUserInstitution` to re-authenticate on the same UID rather than calling plain refresh (stale creds) or create (new UID).

**Provider changes:**
- Add `retry_adding_user_institution(user_institution_id)` — wraps `POST /api/userinstitution/RetryAddingUserInstitution` with body `{ userInstitutionID: <id> }`.

**Controller / wiring changes:**
- In `connect_institution` reconnect path: check item status. If `requires_update`, call `retry_adding_user_institution(existing_uid)` instead of `refresh_user_institution_full_history(existing_uid)`.
- UID is preserved in both cases — de-dup invariant holds.

**Tests:** Minitest. Mock provider for the `requires_update` path vs. normal reconnect path. Confirm UID unchanged in both.

**Coupling note:** Touches the same `connect_institution` region as Phase 1. Sequence strictly after Phase 1 is merged.

---

### Phase 3 — Holdings for investment accounts

**Goal:** Populate Sure's Holdings/Securities model for investment accounts connected via Sophtron.

**Provider changes:**
- Add `get_holdings_by_account_id(account_id)` — wraps `POST /api/holdings/GetHoldingsByAccountId` with body `{ accountID: <id> }`.

**Model / processor changes:**
- Add a holdings processor (analogous to `SophtronAccount::Transactions::Processor`) that maps the Sophtron holdings array to Sure `Holding` / `Security` records for investment-type accounts.
- Likely requires a `raw_holdings_payload` column on `sophtron_account` (DB migration). The user runs migrations manually — do not auto-run.
- Holdings fetch runs after account sync, only for accounts whose `accountType` maps to an investment type.

**Tests:** Minitest. Mock provider response. Verify processor maps fields correctly; verify non-investment accounts skip holdings fetch.

**Coupling note:** Independent of the connect flow and of Phases 1/2. Can be developed in parallel with Phase 4 once Phase 2 is merged (or even earlier, since it touches different files).

---

### Phase 4 — Rewards

**Goal:** Fetch and store credit-card rewards/points balance during sync.

**Provider changes:**
- Add `refresh_user_institution_with_rewards_info(user_institution_id)` — wraps `POST /api/UserInstitution/RefreshUserInstitutionWithRewardsInfo` with `rewards: true`.
- Optionally add the create variant `create_user_institution_with_rewards_info(...)` if rewards should be fetched on initial connect as well.

**Model / storage:**
- Rewards data is available in the `GetUserInstitutionAccounts` response under `creditCardData` (fields: `rewardUnit`, `rewardBalance`, `rewardDescription`). No new endpoint is strictly needed to read the values — the `WithRewardsInfo` refresh variants simply ensure Sophtron refreshes them first.
- Store rewards fields on `sophtron_account` raw payload or surface via account metadata. UI surface is optional and deferred.

**Tests:** Minitest. Mock provider.

**Coupling note:** Mostly independent — touches different files from Phases 1/2 and a different concern from Phase 3. Can follow Phase 3 in any order.

---

## Execution order and coupling

```
Phase 1 (full history)
    |
    v
Phase 2 (re-auth/retry)   <- both touch connect_institution, must be sequential
    |
    +---> Phase 3 (holdings)   <- independent, different files
    |
    +---> Phase 4 (rewards)    <- independent, different files
```

Each phase: branch off `main` → implement + Minitest + `bin/rubocop` + `bin/brakeman` → PR into `YumTaha/sure:main` → Copilot review → merge before next sequential phase.

---

## Out of scope

The following v1 endpoints are NOT included in this plan:

- Full account numbers (`GetUserInstitutionFullAccountNumbers`, `CreateUserInstitutionWithFullAccountNumbers`, `GetFullAccountNumberHolder`, `GetFullAccountNumberWithinJob`) — not appropriate for a personal finance app; exposes full account numbers with no clear user-facing use case.
- Profile / identity (`GetUserInstitutionProfileInfor`, `CreateUserInstitutionWithProfileInfo`) — identity data not currently modelled in Sure.
- `AddInstitution` — institution catalogue management; not a sync concern.
- Check images (`UpdateCheckImages`) — niche; not modelled.
- Single-account refresh (`RefreshUserInstitutionAccount`) — per-account granularity not needed with institution-level refresh.
- Institution lookups by name/routing/ID — already handled separately.
- v2 API migration — shelved; not in scope.

---

## Reference

Endpoint bodies quoted from: `legacy.md` (Sophtron API V1/V2 reference, compiled endpoint spec).

Shipped work this plan builds on:
- `feat/sophtron-dedup` — connection de-dup (reuse-on-reconnect, delete-on-disconnect)
- `fix/sophtron-transactions` — empty snapshot fix
