# Weekly Spending Digest — Design

**Date:** 2026-07-10 (revised from an initial "daily" design)
**Branch:** `feat/daily-spending-digest`
**Status:** Design approved; reworking implementation to the weekly shape.

## Goal
Email a **weekly** summary of the last 7 days of spending — posted (accurate), pending (recent, not-yet-settled), and an estimated total — with a per-category breakdown of posted spend. Monday 7 AM ET. Self-hosted personal use.

## Why weekly + posted/pending (the reasoning that shaped this)
- Card charges sit **pending 2–5 days** before posting. `IncomeStatement.expense_totals` uses `.excluding_pending`, so a "yesterday, posted-only" digest is ~always $0. Useless.
- Including pending naively is **inaccurate**: pre-auth holds (e.g. a $175 Loves gas hold for a $40 fill) inflate pending until it settles.
- Resolution: **weekly window** (most charges post within 7 days → posted is fairly complete) and show **three figures** so the human judges:
  - **Posted (settled)** — accurate, with category breakdown.
  - **Pending (not settled)** — recent activity the posted view misses; flagged as approximate (may include holds).
  - **Estimated total** = posted + pending.
- No `IncomeStatement` change needed: posted via `expense_totals`, pending via `IncomeStatement#totals(transactions_scope: family.transactions.visible.pending, date_range:)`.

## Decisions (locked with user)
- **Cadence:** weekly, targeting **Monday 7:00 AM ET** (DST-correct), recapping the completed prior week (Mon–Sun).
- **Catch-up (self-heal):** the job runs **hourly** (cron `0 * * * *`), not once at 7 AM. Each run computes the most-recent-Monday-7 AM-ET target and sends **once per week** the first time it runs at/after that target — so if the machine was off/asleep at 7 AM Monday, the first hourly run after power-on sends it. A per-family `date` marker `families.last_weekly_digest_sent_on` (= the target Monday's date) prevents duplicate sends. Send-then-mark order: a crash mid-send leaves the marker unset so the next hourly run retries (a rare duplicate email is preferred over a silently-dropped week).
- **Window (anchored):** `end_date = target Monday − 1` (the Sunday); window = `Period.custom(end_date−6 .. end_date)` = the completed Mon–Sun. Anchored to the target week so a late (caught-up) send still reports the correct week, not a "last 7 days from now" shifted window.
- **Figures:** posted total + category breakdown; pending total; estimated total (posted+pending).
- **Pending caveat** shown in the email (may include holds; firms up as it posts).
- **Aesthetic:** "Design 2 / Cards" mockup — green header, three stat tiles (Posted / Pending / Est. total), category rows with proportional bars, amber caveat callout. Responsive 600px table layout, inline styles, no external assets.
- **Recipient:** every user in the family (single admin here). **Mode:** `self_hosted` only. **Currency:** family currency (USD), `Money#format`.
- **Zero-spend:** still send.

## Non-goals (YAGNI / deferred)
- **Budget-progress bars — DEFERRED** (see ROADMAP). When the user configures monthly budgets, the category bars will fill toward a **prorated weekly budget = monthly × 7 ÷ days_in_month** (green/amber/red), with a share-of-spending fallback for un-budgeted categories. Not built now (no budgets configured; nothing to point bars at). For now, category bars show **share of the week's posted spend**.
- No per-account filtering, no preferences UI, no daily/monthly variants.

## Architecture
Reuse existing aggregation; the PORO packages numbers; a mailer renders Design 2; a weekly cron job fans out.

### Components
1. **`Family::WeeklySpendingDigest` (PORO)** — `Family::WeeklySpendingDigest.new(family, end_date:)`, exposed via `Family#weekly_spending_digest(end_date:)`. Window = `Period.custom(start_date: end_date - 6, end_date: end_date)`.
   - `posted_total` (Money) — `income_statement(user: nil).expense_totals(period:).total` wrapped in `Money`.
   - `posted_categories` — `Array<CategoryLine(name, amount:Money, pct:Integer)>` from that period's `.category_totals`: reject subcategories, positive only, sorted desc; `pct` = round(amount / posted_total × 100) for the proportional bar (0 when total is 0).
   - `pending_total` (Money) — `income_statement(user: nil).totals(transactions_scope: family.transactions.visible.pending, date_range: period.date_range).expense_money`.
   - `estimated_total` (Money) — `Money.new(posted_total.amount + pending_total.amount, currency)`.
   - `currency`, `range_label` (e.g. "Jul 3 – Jul 9, 2026").
2. **`SpendingDigestMailer#weekly(user:, digest:)`** — subclasses `ApplicationMailer`; subject `"Last week you spent {estimated_total}"`; multipart. Passes the PORO object directly (sent via `deliver_now` inside the job — no serialization).
3. **Views** — `weekly.html.erb` (Design 2 markup, inline styles, proportional bars) + `weekly.text.erb` (plain fallback).
4. **`WeeklySpendingDigestJob`** (ActiveJob, `queue: :scheduled`) — guard `self_hosted?`; `end_date = Date.current.prev_day` (last completed day); per family → `family.weekly_spending_digest(end_date:)`; per `family.users` → `SpendingDigestMailer.with(user:, digest:).weekly.deliver_now` (in-process, avoids Money serialization); per-family rescue+log+continue.
5. **`config/schedule.yml`** — `weekly_spending_digest`, cron `0 7 * * 1 America/New_York`.

### Data flow
`cron Mon 7 AM ET → WeeklySpendingDigestJob (self_hosted) → family.weekly_spending_digest(end_date: yesterday) → SpendingDigestMailer.with(...).weekly.deliver_now → Gmail SMTP → inbox`

## Error handling
Per-family rescue+log+continue. `deliver_now` inside the async worker; comment explains why (Money not serializable across `deliver_later`).

## Testing (Minitest + fixtures, `travel_to`; no system tests)
1. **`Family::WeeklySpendingDigest`** — posted transactions across the 7-day window + a pending transaction (via `extra` provider flag) + one outside the window → assert `posted_total`, `posted_categories` (breakdown, pct, order), `pending_total` (only the pending one), `estimated_total` = posted+pending. Zero-spend → zeros, empty categories. Deterministic via `travel_to`.
2. **`SpendingDigestMailer#weekly`** — renders HTML+text, subject/recipient, body shows posted/pending/estimated + category names; zero case clean.
3. **`WeeklySpendingDigestJob`** — `assert_emails <family-user-count>` around `perform_now` (forces real render); managed mode → `assert_no_emails`.

## Deploy
`feat/daily-spending-digest` → PR → review → merge → prod deploy (worktree checkout main + `docker compose up -d --build`). Cron loads on worker boot; SMTP verified in prod.

---

## Budget-progress bars (2026-07-12 increment — branch `feat/digest-budget-bars`)
User configured monthly budgets, so the category bars now track budget instead of share-of-week (for budgeted categories).

**Per category (posted spend for the week):**
- Find the family Budget whose period covers the window's end date: `family.budgets.detect { |b| (b.start_date..b.end_date).cover?(end_date) }`.
- Monthly limit for the category = that budget's `budget_categories` where `category_id` matches, value `bc[:budgeted_spending]` (BigDecimal; skip nil/zero → treat as un-budgeted).
- **Prorated weekly target** = `monthly_limit * 7 / budget_period_days` where `budget_period_days = (b.end_date - b.start_date).to_i + 1` (handles custom month boundaries; e.g. $200/mo, 31-day July → ~$45.16/wk).
- `budget_pct` = `(posted_category_amount / weekly_target * 100).round` (posted only — the bar stays accurate vs budget; pending stays in its own line).
- **Status / color:** `<80% green (#059669)`, `80–100% amber (#D97706)`, `>100% red (#DC2626)`. Bar width = `min(budget_pct, 100)%` (red when over).
- Show `spent of $weekly_target` label.

**Un-budgeted spent categories** (no budget, or no budget for the month): keep the current behavior — neutral **gray (#9CA3AF)** bar = share of the week's posted spend (`pct` field), no target label. Listed after budgeted ones.

**PORO change:** `CategoryLine` gains `weekly_budget` (Money or nil), `budget_pct` (Integer or nil), `status` (`:under`/`:near`/`:over`/`:none`). `pct` (share) retained for the un-budgeted fallback.

**Testing:** category under/near/over its prorated weekly budget → correct status; un-budgeted category → `:none` + gray share bar; no-budget-month → all categories `:none`; proration math (limit×7÷period_days).

**Deploy:** Option A — branch → PR → Copilot review → merge → then deploy merged main to prod. No prod mutation before merge.
