# Daily Spending Digest — Design

**Date:** 2026-07-10
**Branch:** `feat/daily-spending-digest`
**Status:** Design approved; pending implementation plan.

## Goal
Email the user a daily summary of yesterday's spending (with month-to-date context), broken down by category, delivered at 7:00 AM ET. Self-hosted personal use.

## Decisions (locked with user)
- **Window:** yesterday (previous full calendar day) as the headline, plus a month-to-date (MTD) total for context.
- **Detail:** yesterday's total + per-category breakdown; MTD total line.
- **Send time:** 7:00 AM ET, DST-correct.
- **Format:** styled HTML (app `mailer` layout) with a plain-text multipart fallback.
- **Zero-spend days:** still send (`"You spent $0 yesterday"`) — daily habit + pipeline heartbeat.
- **Recipient:** every user in the family (single admin account in this deployment).
- **Mode:** `self_hosted` only (inert in managed mode). On by default; no toggle (YAGNI).
- **Currency:** family currency (USD), formatted server-side via `Money`.

## Non-goals (YAGNI)
- No per-account filtering, no user-configurable schedule/preferences UI, no weekly/monthly variants, no in-app digest view, no opt-in/out toggle (add later only if requested).

## Architecture — reuse existing aggregation
The app already computes spend via `IncomeStatement`. **No new spend query is written.** The digest is a thin packaging layer.

### Components (each one concern)
1. **`Family::SpendingDigest` (PORO)** — the only new domain logic. Constructed with `(family, date:)`; exposes a plain value object:
   - `yesterday_total` (Money) — `income_statement.expense_totals(period: Period.custom(start_date: date, end_date: date)).total`
   - `yesterday_categories` — array of `{ name, amount }` from that period's `.category_totals` (drop zero/negative, sort desc, exclude uncategorized-investment rows).
   - `mtd_total` (Money) — `expense_totals` for `Period.custom(start_date: date.beginning_of_month, end_date: date)`.
   - `currency`.
   - `expense_totals` uses `classification: "expense"`, so investment trades (Robinhood) are excluded from "spending" — verify `include_trades` handling in the plan (want expenses only).
   - Exposed via `Family#spending_digest(date:)` returning the PORO (fat-model convention).
2. **`SpendingDigestMailer#daily(user:, digest:)`** — subclasses `ApplicationMailer` (inherits `EMAIL_SENDER` default from). Subject: `"Yesterday you spent {yesterday_total}"`. Multipart.
3. **Views** — `app/views/spending_digest_mailer/daily.html.erb` (styled, `mailer` layout: total, MTD line, category rows) + `daily.text.erb` (plain fallback).
4. **`DailySpendingDigestJob` (ActiveJob, `queue: :scheduled`)** — guard: return unless `Rails.application.config.app_mode.self_hosted?`. For each `Family`, build `family.spending_digest(date: Date.current.yesterday)`, then for each family user `SpendingDigestMailer.daily(user:, digest:).deliver_later`.
5. **`config/schedule.yml`** entry:
   ```yaml
   daily_spending_digest:
     cron: "0 7 * * * America/New_York"   # 7 AM ET, DST-correct via Fugit
     class: "DailySpendingDigestJob"
     queue: "scheduled"
     description: "Emails each family a daily spending digest (yesterday + MTD)"
   ```
   Fallback if the TZ suffix is unsupported by the installed sidekiq-cron/Fugit: `"0 11 * * *"` (UTC ≈ 7 AM ET, drifts 1h across DST — matches the pattern the existing crons already accept).

### Data flow
```
cron (7 AM ET)
  → DailySpendingDigestJob   (self_hosted guard)
    → family.spending_digest(date: yesterday)      # wraps IncomeStatement.expense_totals ×2
      → SpendingDigestMailer.daily(user:, digest:).deliver_later
        → Gmail SMTP → inbox
```

## Error handling
- Per-family failure isolated: rescue inside the family loop, log, continue (one family's error never blocks others). Single-family here, but keeps the job robust.
- Mailer delivery via `deliver_later` (Sidekiq) — transient SMTP failures retry via Sidekiq's retry.

## Testing (Minitest + fixtures; no system tests)
1. **`Family::SpendingDigest`** — fixture transactions across ≥2 categories on the target date + earlier in the month → assert `yesterday_total`, `yesterday_categories` (breakdown + order), `mtd_total`. Edge: zero-spend day → totals are 0, empty categories.
2. **`DailySpendingDigestJob`** — asserts a mailer is enqueued per family user with the right digest (mocha); asserts it no-ops when `app_mode` is managed.
3. **`SpendingDigestMailer#daily`** — renders HTML + text, correct subject/recipient; `$0` case renders cleanly.

## Deploy
Ships as `feat/daily-spending-digest` → PR → review → merge to fork `main` → prod deploy (worktree `checkout main` + `docker compose up -d --build`). The sidekiq-cron entry loads on worker boot; SMTP pipe already verified in production.
