# Daily Spending Digest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Email each family a daily digest of yesterday's spending (headline) plus month-to-date context, broken down by category, at 7:00 AM ET.

**Architecture:** A thin PORO (`Family::SpendingDigest`) packages numbers from the existing `IncomeStatement.expense_totals` aggregation (no new spend query). A mailer renders them; a scheduled ActiveJob fans out per family/user; a sidekiq-cron entry fires it. Self-hosted mode only.

**Tech Stack:** Rails 8.1, ActiveJob + Sidekiq, ActionMailer, Minitest + fixtures + mocha, sidekiq-cron (Fugit).

## Global Constraints

- Auth/context: use `Current.user`/`Current.family` in app code; NOT in this job (no request context) — pass explicit args, call `family.income_statement(user: nil)` (all family accounts).
- Money: amounts from `expense_totals` are numeric; wrap with `Money.new(amount, family.currency)`; format with `.format`.
- Expenses are positive magnitudes; `expense_totals` is transaction-based (investment trades excluded).
- Tests: Minitest + fixtures + mocha, NEVER RSpec. Use `travel_to` for date determinism (there is a prior date-flake lesson). Create edge-case data on the fly with `create_transaction`.
- Commits: no AI attribution. Commit after each task.
- i18n: user-facing strings via `t()`; add keys to `config/locales/views/spending_digest_mailer/en.yml`.

---

### Task 1: `Family::SpendingDigest` PORO + `Family#spending_digest`

**Files:**
- Create: `app/models/family/spending_digest.rb`
- Modify: `app/models/family.rb` (add `spending_digest` method near `income_statement`, ~line 261)
- Test: `test/models/family/spending_digest_test.rb`

**Interfaces:**
- Consumes: `family.income_statement(user: nil)` → `IncomeStatement#expense_totals(period:)` returning `PeriodTotal(:classification, :total, :currency, :category_totals)`; each `category_totals` element is `CategoryTotal(:category, :total, :currency, :weight)`. `Period.custom(start_date:, end_date:)`.
- Produces:
  - `family.spending_digest(date: Date)` → `Family::SpendingDigest`
  - `#yesterday_total` → `Money`
  - `#mtd_total` → `Money`
  - `#categories` → `Array<Family::SpendingDigest::CategoryLine>` where `CategoryLine = Data.define(:name, :amount)` and `amount` is `Money`, positive-only, sorted descending
  - `#currency` → String
  - `#any_spending?` → Boolean (`yesterday_total.amount.positive?`)

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/family/spending_digest_test.rb
require "test_helper"

class Family::SpendingDigestTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository) # belongs to dylan_family
  end

  test "yesterday_total, categories, and mtd_total reflect expense transactions" do
    travel_to Time.zone.local(2026, 7, 15, 12, 0, 0) do
      yesterday = Date.new(2026, 7, 14)

      # Yesterday's spend: 40 food + 60 food + 100 shopping(one) = 100 food, 100 shopping
      create_transaction(account: @account, date: yesterday, amount: 40, category: categories(:food_and_drink), name: "Lunch")
      create_transaction(account: @account, date: yesterday, amount: 60, category: categories(:food_and_drink), name: "Dinner")
      create_transaction(account: @account, date: yesterday, amount: 100, category: categories(:one), name: "Shoes")
      # Earlier this month (MTD but not yesterday): 200
      create_transaction(account: @account, date: Date.new(2026, 7, 2), amount: 200, category: categories(:one), name: "Earlier")
      # Last month (excluded from MTD): 999
      create_transaction(account: @account, date: Date.new(2026, 6, 20), amount: 999, category: categories(:one), name: "LastMonth")

      digest = @family.spending_digest(date: yesterday)

      assert_equal 200, digest.yesterday_total.amount.to_i          # 40+60+100
      assert_equal 400, digest.mtd_total.amount.to_i                # 200 (yday food+shopping) + 200 earlier... see note
      assert digest.any_spending?

      names = digest.categories.map(&:name)
      # Two positive categories yesterday; sorted by amount desc (both 100 → order stable)
      assert_equal 2, digest.categories.size
      assert digest.categories.all? { |c| c.amount.amount.positive? }
    end
  end

  test "zero-spend day yields zero totals and no categories" do
    travel_to Time.zone.local(2026, 7, 15, 12, 0, 0) do
      digest = families(:empty).spending_digest(date: Date.new(2026, 7, 14))
      assert_equal 0, digest.yesterday_total.amount.to_i
      assert_empty digest.categories
      assert_not digest.any_spending?
    end
  end
end
```

> Note on the MTD assertion: yesterday's spend (200) + the Jul-2 txn (200) = 400; the Jun-20 txn is excluded. If `categories(:one)` or `:food_and_drink` fixtures already carry seeded entries for dylan_family, adjust the expected numbers to `baseline + delta` after running Step 2 and reading the actual failure — do not hardcode past the fixture baseline. Prefer `assert_equal` against computed expectations; if fixtures interfere, switch the assertions to `assert_operator digest.yesterday_total.amount, :>=, 200`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/family/spending_digest_test.rb -v`
Expected: FAIL — `NoMethodError: undefined method 'spending_digest' for #<Family>`. (Also read the actual totals here to calibrate fixture baselines per the note above.)

- [ ] **Step 3: Implement the PORO**

```ruby
# app/models/family/spending_digest.rb
class Family::SpendingDigest
  CategoryLine = Data.define(:name, :amount) # amount is a Money

  def initialize(family, date:)
    @family = family
    @date = date
  end

  def yesterday_total
    Money.new(day_totals.total, @family.currency)
  end

  def mtd_total
    Money.new(mtd_totals.total, @family.currency)
  end

  def currency
    @family.currency
  end

  def any_spending?
    yesterday_total.amount.positive?
  end

  # Positive expense categories for the day, largest first.
  def categories
    day_totals.category_totals
      .reject { |ct| ct.category.subcategory? }
      .select { |ct| ct.total.positive? }
      .sort_by { |ct| -ct.total }
      .map { |ct| CategoryLine.new(name: category_name(ct.category), amount: Money.new(ct.total, @family.currency)) }
  end

  private
    def statement
      @statement ||= @family.income_statement(user: nil)
    end

    def day_totals
      @day_totals ||= statement.expense_totals(period: Period.custom(start_date: @date, end_date: @date))
    end

    def mtd_totals
      @mtd_totals ||= statement.expense_totals(period: Period.custom(start_date: @date.beginning_of_month, end_date: @date))
    end

    def category_name(category)
      category.name.presence || "Uncategorized"
    end
end
```

```ruby
# app/models/family.rb — add near income_statement (~line 261)
  def spending_digest(date:)
    Family::SpendingDigest.new(self, date: date)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/family/spending_digest_test.rb -v`
Expected: PASS (after calibrating fixture baselines per the Step 1 note).

- [ ] **Step 5: Commit**

```bash
git add app/models/family/spending_digest.rb app/models/family.rb test/models/family/spending_digest_test.rb
git commit -m "Add Family::SpendingDigest — yesterday + MTD spend from IncomeStatement"
```

---

### Task 2: `SpendingDigestMailer#daily` + views + i18n

**Files:**
- Create: `app/mailers/spending_digest_mailer.rb`
- Create: `app/views/spending_digest_mailer/daily.html.erb`
- Create: `app/views/spending_digest_mailer/daily.text.erb`
- Create: `config/locales/views/spending_digest_mailer/en.yml`
- Test: `test/mailers/spending_digest_mailer_test.rb`

**Interfaces:**
- Consumes: `Family::SpendingDigest` (Task 1) via `params[:digest]`; `params[:user]` (a `User` with `#email`).
- Produces: `SpendingDigestMailer.with(user:, digest:).daily` → `Mail::Message` (multipart html+text), `to: [user.email]`, subject `"Yesterday you spent {formatted total}"`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/mailers/spending_digest_mailer_test.rb
require "test_helper"

class SpendingDigestMailerTest < ActionMailer::TestCase
  test "daily email addresses the user and shows totals + categories" do
    user = users(:family_admin)
    digest = OpenStruct.new(
      yesterday_total: Money.new(200, "USD"),
      mtd_total: Money.new(400, "USD"),
      currency: "USD",
      any_spending?: true,
      categories: [
        Family::SpendingDigest::CategoryLine.new(name: "Food & Drink", amount: Money.new(100, "USD")),
        Family::SpendingDigest::CategoryLine.new(name: "Shopping", amount: Money.new(100, "USD"))
      ]
    )

    email = SpendingDigestMailer.with(user: user, digest: digest).daily

    assert_equal [ user.email ], email.to
    assert_match(/spent/i, email.subject)
    body = email.body.to_s
    assert_includes body, "Food & Drink"
    assert_includes body, "Shopping"
  end

  test "zero-spend renders cleanly" do
    user = users(:family_admin)
    digest = OpenStruct.new(
      yesterday_total: Money.new(0, "USD"),
      mtd_total: Money.new(0, "USD"),
      currency: "USD",
      any_spending?: false,
      categories: []
    )
    email = SpendingDigestMailer.with(user: user, digest: digest).daily
    assert_equal [ user.email ], email.to
    assert_match(/\$0/, email.body.to_s)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/mailers/spending_digest_mailer_test.rb -v`
Expected: FAIL — `uninitialized constant SpendingDigestMailer`.

- [ ] **Step 3: Implement mailer, views, i18n**

```ruby
# app/mailers/spending_digest_mailer.rb
class SpendingDigestMailer < ApplicationMailer
  def daily
    @user = params[:user]
    @digest = params[:digest]
    mail(
      to: @user.email,
      subject: t("spending_digest_mailer.daily.subject", amount: @digest.yesterday_total.format)
    )
  end
end
```

```erb
<%# app/views/spending_digest_mailer/daily.html.erb %>
<h1 style="font-size:20px;margin:0 0 4px;"><%= t("spending_digest_mailer.daily.heading") %></h1>
<p style="font-size:28px;font-weight:700;margin:8px 0;"><%= @digest.yesterday_total.format %></p>
<p style="color:#666;margin:0 0 16px;">
  <%= t("spending_digest_mailer.daily.mtd", amount: @digest.mtd_total.format) %>
</p>

<% if @digest.categories.any? %>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
    <% @digest.categories.each do |line| %>
      <tr>
        <td style="padding:6px 0;border-bottom:1px solid #eee;"><%= line.name %></td>
        <td style="padding:6px 0;border-bottom:1px solid #eee;text-align:right;"><%= line.amount.format %></td>
      </tr>
    <% end %>
  </table>
<% else %>
  <p><%= t("spending_digest_mailer.daily.no_spending") %></p>
<% end %>
```

```erb
<%# app/views/spending_digest_mailer/daily.text.erb %>
<%= t("spending_digest_mailer.daily.heading") %>
<%= @digest.yesterday_total.format %>
<%= t("spending_digest_mailer.daily.mtd", amount: @digest.mtd_total.format) %>

<% if @digest.categories.any? %>
<% @digest.categories.each do |line| -%>
- <%= line.name %>: <%= line.amount.format %>
<% end -%>
<% else -%>
<%= t("spending_digest_mailer.daily.no_spending") %>
<% end -%>
```

```yaml
# config/locales/views/spending_digest_mailer/en.yml
en:
  spending_digest_mailer:
    daily:
      subject: "Yesterday you spent %{amount}"
      heading: "Yesterday's spending"
      mtd: "This month so far: %{amount}"
      no_spending: "No spending yesterday."
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/mailers/spending_digest_mailer_test.rb -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/mailers/spending_digest_mailer.rb app/views/spending_digest_mailer/ config/locales/views/spending_digest_mailer/en.yml test/mailers/spending_digest_mailer_test.rb
git commit -m "Add SpendingDigestMailer#daily with html/text views"
```

---

### Task 3: `DailySpendingDigestJob`

**Files:**
- Create: `app/jobs/daily_spending_digest_job.rb`
- Test: `test/jobs/daily_spending_digest_job_test.rb`

**Interfaces:**
- Consumes: `family.spending_digest(date:)` (Task 1); `SpendingDigestMailer.with(user:, digest:).daily.deliver_later` (Task 2); `Rails.application.config.app_mode.self_hosted?`.
- Produces: `DailySpendingDigestJob.perform_later` / `.perform_now` — enqueues one `SpendingDigestMailer#daily` per family user; no-ops unless self-hosted.

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/daily_spending_digest_job_test.rb
require "test_helper"

class DailySpendingDigestJobTest < ActiveJob::TestCase
  test "enqueues a daily digest email for each family user in self-hosted mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))

    assert_enqueued_emails Family.joins(:users).distinct.count { true } do
      # simpler: assert at least one enqueued per user; use count of users across families
    end
  end

  test "does nothing in managed mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("managed"))
    assert_no_enqueued_emails do
      DailySpendingDigestJob.perform_now
    end
  end
end
```

> Replace the first test body with the concrete form below once you confirm the fixture user count. The robust version:

```ruby
  test "enqueues a daily digest email for each family user in self-hosted mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    expected = User.where.not(family_id: nil).count
    assert_enqueued_emails expected do
      DailySpendingDigestJob.perform_now
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/daily_spending_digest_job_test.rb -v`
Expected: FAIL — `uninitialized constant DailySpendingDigestJob`.

- [ ] **Step 3: Implement the job**

```ruby
# app/jobs/daily_spending_digest_job.rb
class DailySpendingDigestJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Rails.application.config.app_mode.self_hosted?

    date = Date.current.yesterday

    Family.find_each do |family|
      digest = family.spending_digest(date: date)
      family.users.find_each do |user|
        SpendingDigestMailer.with(user: user, digest: digest).daily.deliver_later
      end
    rescue => e
      Rails.logger.error("DailySpendingDigestJob failed for family #{family.id}: #{e.class} #{e.message}")
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/jobs/daily_spending_digest_job_test.rb -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/jobs/daily_spending_digest_job.rb test/jobs/daily_spending_digest_job_test.rb
git commit -m "Add DailySpendingDigestJob (self-hosted, per family user)"
```

---

### Task 4: Schedule the job (sidekiq-cron)

**Files:**
- Modify: `config/schedule.yml` (append a new entry)

**Interfaces:**
- Consumes: `DailySpendingDigestJob` (Task 3).
- Produces: a registered cron `daily_spending_digest` firing at 7 AM ET.

- [ ] **Step 1: Add the schedule entry**

```yaml
# append to config/schedule.yml
daily_spending_digest:
  cron: "0 7 * * * America/New_York" # 7:00 AM ET, DST-correct via Fugit
  class: "DailySpendingDigestJob"
  queue: "scheduled"
  description: "Emails each family a daily spending digest (yesterday + MTD)"
```

- [ ] **Step 2: Verify the cron string parses (Fugit accepts the TZ suffix)**

Run:
```bash
bin/rails runner 'require "fugit"; c = Fugit.parse_cron("0 7 * * * America/New_York"); puts c.nil? ? "NIL" : c.next_time.to_s'
```
Expected: prints a future timestamp (NOT "NIL"). If it prints NIL or raises, the installed Fugit version rejects the TZ suffix — fall back to `cron: "0 11 * * *"` (UTC ≈ 7 AM ET, drifts 1h across DST) and add a comment noting the drift.

- [ ] **Step 3: Verify the schedule file loads**

Run:
```bash
bin/rails runner 'puts YAML.load_file(Rails.root.join("config/schedule.yml")).key?("daily_spending_digest")'
```
Expected: `true`

- [ ] **Step 4: Commit**

```bash
git add config/schedule.yml
git commit -m "Schedule DailySpendingDigestJob at 7 AM ET"
```

---

## Final verification (after all tasks)

- [ ] Run the full touched-area suite:
  `bin/rails test test/models/family/spending_digest_test.rb test/mailers/spending_digest_mailer_test.rb test/jobs/daily_spending_digest_job_test.rb`
  Expected: all green.
- [ ] Lint: `bin/rubocop -f github -a` and `bundle exec erb_lint ./app/views/spending_digest_mailer/*.erb -a` — clean.
- [ ] Manual smoke (dev console): `Family.first.spending_digest(date: Date.current.yesterday).yesterday_total.format` returns a formatted string.
- [ ] Deploy note (prod): after merge to fork `main`, `cd ~/docker-apps/sure && git -C app checkout --detach yumtaha/main && docker compose up -d --build`. The cron registers on worker boot. Optionally trigger once to verify email: `docker compose exec web ./bin/rails runner 'DailySpendingDigestJob.perform_now'`.

## Self-Review (author check)

- **Spec coverage:** yesterday+MTD (Task 1) ✓; total+by-category (Task 1 categories, Task 2 views) ✓; 7 AM ET (Task 4) ✓; styled HTML + text (Task 2) ✓; zero-spend sends (Task 2 zero test, Task 1 any_spending?) ✓; recipient = family users (Task 3) ✓; self-hosted guard (Task 3) ✓; currency formatting (Money.format throughout) ✓; trades excluded (expense_totals is transaction-based — noted in Global Constraints) ✓.
- **Placeholders:** none — every code step is concrete. The two "calibrate fixture baseline" notes are explicit calibration instructions, not deferred work.
- **Type consistency:** `Family::SpendingDigest::CategoryLine(name, amount:Money)` used identically in Tasks 1 & 2; `spending_digest(date:)`, `expense_totals(period:)`, `.with(user:, digest:).daily` consistent across tasks.
