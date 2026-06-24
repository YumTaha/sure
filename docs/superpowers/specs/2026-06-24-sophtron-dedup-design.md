# Sophtron Connection De-duplication

**Date:** 2026-06-24
**Branch:** `feat/sophtron-dedup`
**API version:** Sophtron v1 (legacy) — v2 migration is out of scope

---

## Problem

Sure creates a new `SophtronItem` and a new Sophtron `UserInstitution` on every (re)connect. On disconnect, it removes only the local record and never deletes the connection at Sophtron. The result: orphaned and duplicate connections accumulate under a single Sophtron UserID over time.

---

## Approach

Two complementary fixes — one on the connect side, one on the disconnect side.

### (a) Reuse on Reconnect (connect side)

**Touch points:** `SophtronItemsController` connect action and `item_for_institution_connection` (~line 985).

**Logic:** Before creating a new item, look up an existing one:

```ruby
existing = Current.family.sophtron_items.find_by(institution_id: params[:institution_id])
```

| Result | Behavior |
|--------|----------|
| Found | Reuse it: update credentials on its existing `UserInstitution` via `update_user_institution`, then re-run aggregation via `refresh_user_institution`. No new `SophtronItem` created. No new Sophtron `UserInstitution` created. Continue into the same poll/MFA flow. |
| Not found | Current behavior — create a new `SophtronItem` and `UserInstitution`. |

**New provider methods required:**

- `update_user_institution` → `POST /api/userinstitution/UpdateUserInstitution`
- `refresh_user_institution` (re-run aggregation) → `POST /api/UserInstitution/RefreshUserInstitution`

**Outcome:** Exactly one `SophtronItem` and one Sophtron `UserInstitution` per `(family, institution)` pair. Reuse is automatic and silent to the user.

---

### (b) Delete on Disconnect (disconnect side)

**Touch point:** `SophtronItem` destroy path (`SophtronItemsController#destroy` ~line 423).

**New provider method required:**

- `delete_user_institution(user_institution_id)` → `POST /api/UserInstitution/DeleteUserInstitution`
  - Request body: `{ userInstitutionID: <id> }`

**Behavior:**

- Best-effort: call the remote delete before removing the local record.
- On API error: record a `DebugLogEntry` and **still** remove the local `SophtronItem` — never leave the user stuck.
- Skip the remote call entirely when the item has no `user_institution_id` (never fully connected).
- The remote-delete logic lives in the model (fat-model convention), invoked from `destroy`.

---

## One-Time Cleanup (manual, never merged)

A `bin/rails runner` script kept in a local scratchpad — never committed to the repo. It:

1. Enumerates all `UserInstitution` records via `POST /api/UserInstitution/GetUserInstitutionsByUser`.
2. **Excludes** any `UserInstitution` belonging to the other app's customer (UniversalWidget) to avoid breaking it.
3. Presents the proposed delete list for manual confirmation.
4. Calls `DeleteUserInstitution` for each confirmed entry.

Credentials are supplied at runtime via environment variables — never hardcoded or committed.

---

## Tests

Framework: Minitest + fixtures + mocha. All provider calls are mocked — no live API calls.

| # | Scenario | Assertion |
|---|----------|-----------|
| 1 | Reconnecting an institution that already has a `SophtronItem` | Reuses the existing item: `SophtronItem.count` unchanged; `update_user_institution` called once; `create_user_institution` NOT called. |
| 2 | Connecting a brand-new institution | Creates exactly one new `SophtronItem`; `create_user_institution` called once. |
| 3 | Destroy — happy path | `delete_user_institution(uiid)` called; local record destroyed. |
| 4 | Destroy — API error | Local record still destroyed; `DebugLogEntry` created with relevant metadata. |

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Existing item is in an error state | Reuse path calls `refresh_user_institution` to re-run aggregation and recover the connection. |
| Item with `nil` `user_institution_id` (never fully connected) | Local-only delete; skip remote call. |
| MFA required during reconnect | Reuse path feeds into the same job/poll/MFA flow as a new connection — no special handling needed. |

---

## Out of Scope

- **v2 API migration** — shelved; all changes stay on v1.
- **Extended history backfill** — v1 provides `CreateUserInstitutionWithFullHistory` if this is ever needed in the future, but it is not part of this spec.
