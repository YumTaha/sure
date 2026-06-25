# Sophtron Refresh MFA Recovery

**Date:** 2026-06-24
**Status:** SHIPPED (branch `fix/sophtron-refresh-mfa-recovery`)
**Primary files:** `app/models/sophtron_item.rb`, `app/views/sophtron_items/_sophtron_item.html.erb`, `app/jobs/sophtron_refresh_poll_job.rb`, `config/locales/views/sophtron_items/en.yml`

---

## Background

A Sophtron background refresh (`SyncJob` → `SophtronRefreshPollJob`) that encounters an MFA challenge calls `mark_requires_update!`, which sets `status=requires_update`, `current_job_id`, and `last_connection_error="Sophtron refresh requires MFA"`, then stops. The working foreground MFA path (`SophtronItemsController#start_manual_sync` → `start_manual_sync_for_account` → `render :mfa`) is unreachable because:

1. The Sophtron item partial has no `requires_update` UI state — nothing signals the user.
2. `manual_sync_required?` returns false for a `requires_update` item, so the `sync` action routes to an automatic background sync rather than the interactive foreground path.

Result: accounts that require MFA on every refresh (e.g. Apple Card) are permanently stuck after the first background sync attempt.

---

## Root Cause

```
SophtronRefreshPollJob#perform
  → job_requires_input?(job) → true
  → mark_requires_update!(sophtron_item, job_id)   # sets status=requires_update, stores job_id
  → returns (stops)

SophtronItemsController#sync
  → manual_sync_required?  # returns false — doesn't check requires_update?
  → sophtron_item.sync_later   # queues another background sync that will MFA again
```

---

## Strategy

Reuse the existing foreground manual-sync MFA machinery for `requires_update` items. The foreground path already handles MFA correctly end-to-end. We only need to route `requires_update` items into it.

Four targeted changes:

1. **`sophtron_item.rb`** — extend `manual_sync_required?` and `manual_sync_sophtron_accounts` to include `requires_update?` items.
2. **`_sophtron_item.html.erb`** — surface a warning status row and a "Reconnect" button when the item is `requires_update`.
3. **`sophtron_refresh_poll_job.rb`** — clear stale error state and restore `status: :good` on the success path after import.
4. **`config/locales/views/sophtron_items/en.yml`** — add `requires_update` and `reconnect` translation keys.

---

## Changes

### 1. `app/models/sophtron_item.rb`

**`manual_sync_required?`:** Add `requires_update?` so a stuck item routes to the foreground path.

```ruby
# Before:
def manual_sync_required?
  manual_sync? || sophtron_accounts.requires_manual_sync.exists?
end

# After:
def manual_sync_required?
  manual_sync? || requires_update? || sophtron_accounts.requires_manual_sync.exists?
end
```

**`manual_sync_sophtron_accounts`:** Return linked accounts for a `requires_update` item so the foreground sync has accounts to refresh.

```ruby
# Before (final line):
manual_sync? ? linked_accounts : linked_accounts.none

# After:
(manual_sync? || requires_update?) ? linked_accounts : linked_accounts.none
```

`requires_update?` is the standard Rails enum predicate — no new method needed.

---

### 2. `app/views/sophtron_items/_sophtron_item.html.erb`

**Status area:** Add a `requires_update?` branch (placed before the `sync_error` branch, mirroring `_plaid_item.html.erb`).

```erb
<%# ... existing syncing? branch ... %>
<% elsif sophtron_item.requires_update? %>
  <div class="text-warning flex items-center gap-1">
    <%= icon "alert-triangle", size: "sm", color: "warning" %>
    <%= tag.span t(".requires_update") %>
  </div>
<%# ... existing sync_error? branch ... %>
```

**Button area:** When `requires_update?`, render the button with `title: t(".reconnect")` and `frame: "modal"` (so the MFA form renders in the existing modal). For the non-requires_update case, keep existing behavior (no frame for dev, frame for manual_sync).

---

### 3. `app/jobs/sophtron_refresh_poll_job.rb`

On the success path, immediately before `account.sync_later(...)`, clear any stale error and restore good status:

```ruby
sophtron_item.update!(last_connection_error: nil, status: :good) if sophtron_item.requires_update? || sophtron_item.last_connection_error.present?
```

This is idempotent (the update is a no-op if already clean) and handles the case where a prior MFA challenge's `mark_requires_update!` left error state on the item.

---

### 4. i18n

In `config/locales/views/sophtron_items/en.yml`, under the `sophtron_item:` key (alongside `sync_now`, `error`, etc.):

```yaml
requires_update: "Reconnect required"
reconnect: "Reconnect"
```

---

## Out of Scope / Follow-Up

**(a) Transient `job_failed?` re-poll hardening:** When a background refresh job genuinely fails (network glitch, Sophtron outage), the account sets `last_connection_error` but does not retry. A follow-up could add bounded retry with exponential back-off in `SophtronRefreshPollJob` for transient failures.

**(b) Proactive notification for cron-triggered `requires_update`:** When a scheduled nightly sync marks an item `requires_update`, the user currently only discovers this by navigating to the accounts page and seeing the warning. A future improvement could send an in-app or email notification prompting them to reconnect.
