require "test_helper"

class Family::WeeklySpendingDigestTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository) # belongs to dylan_family
  end

  test "posted_total, posted_categories, pending_total, and estimated_total reflect the 7-day window" do
    travel_to Time.zone.local(2026, 7, 15, 12, 0, 0) do
      end_date = Date.new(2026, 7, 14) # window: Jul 8 - Jul 14

      # Posted, inside window
      create_transaction(account: @account, date: Date.new(2026, 7, 10), amount: 40, category: categories(:food_and_drink), name: "Lunch")
      create_transaction(account: @account, date: Date.new(2026, 7, 12), amount: 60, category: categories(:food_and_drink), name: "Dinner")
      create_transaction(account: @account, date: Date.new(2026, 7, 12), amount: 100, category: categories(:one), name: "Shoes")

      # Posted, OUTSIDE window (excluded)
      create_transaction(account: @account, date: Date.new(2026, 7, 1), amount: 999, category: categories(:one), name: "OutsideWindow")

      # Pending, inside window
      pending_entry = create_transaction(account: @account, date: Date.new(2026, 7, 11), amount: 50, category: categories(:food_and_drink), name: "GasHold")
      pending_entry.entryable.update!(extra: { "plaid" => { "pending" => true } })

      # Pending, OUTSIDE window (must be excluded from pending_total)
      outside_pending_entry = create_transaction(account: @account, date: Date.new(2026, 6, 20), amount: 500, category: categories(:food_and_drink), name: "OldHold")
      outside_pending_entry.entryable.update!(extra: { "plaid" => { "pending" => true } })

      digest = @family.weekly_spending_digest(end_date: end_date, user: users(:family_admin))

      assert_equal "Jul 8 – Jul 14, 2026", digest.range_label
      assert_equal "USD", digest.currency

      # Posted total excludes the pending txn and the out-of-window txn; at least our 40+60+100=200
      # (fixture baseline adds a small amount of noise inside the window, hence >=)
      assert_operator digest.posted_total.amount, :>=, 200

      assert_equal Money.new(50, "USD"), digest.pending_total

      assert_equal digest.posted_total.amount + 50, digest.estimated_total.amount

      categories = digest.posted_categories
      assert_operator categories.size, :>=, 2
      names = categories.map(&:name)
      assert_includes names, "Food & Drink"
      assert_includes names, categories(:one).name

      # This test doesn't set any per-category budget limits for the window, so every
      # category should be treated as un-budgeted.
      categories.each do |line|
        assert_equal :none, line.status
        assert_nil line.weekly_budget
        assert_nil line.budget_pct
      end

      # pct is sane (0..100)
      categories.each do |line|
        assert_operator line.pct, :>=, 0
        assert_operator line.pct, :<=, 100
      end

      food_line = categories.find { |c| c.name == "Food & Drink" }
      assert_operator food_line.amount.amount, :>=, 100 # 40 + 60
      expected_pct = ((food_line.amount.amount.to_d / digest.posted_total.amount) * 100).round
      assert_equal expected_pct, food_line.pct
    end
  end

  test "zero-spend week yields zero totals and no categories" do
    travel_to Time.zone.local(2026, 7, 15, 12, 0, 0) do
      digest = families(:empty).weekly_spending_digest(end_date: Date.new(2026, 7, 14), user: users(:empty))
      assert_equal 0, digest.posted_total.amount.to_i
      assert_equal 0, digest.pending_total.amount.to_i
      assert_equal 0, digest.estimated_total.amount.to_i
      assert_empty digest.posted_categories
    end
  end

  test "budgeted category shows prorated weekly target, :near status, and sorts before un-budgeted categories" do
    travel_to Time.zone.local(2026, 3, 16, 12, 0, 0) do
      end_date = Date.new(2026, 3, 15) # window: Mar 9 - Mar 15 (March has 31 days)

      budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 3, 1))
      food_budget_category = budget.budget_categories.reload.find { |bc| bc.category_id == categories(:food_and_drink).id }
      food_budget_category.update_budgeted_spending!(200)

      # Food & Drink: budgeted at $200/mo -> weekly target = 200 * 7 / 31 ~= $45.16.
      # $40 spend / $45.16 target ~= 88.6% -> :near
      create_transaction(account: @account, date: Date.new(2026, 3, 11), amount: 40, category: categories(:food_and_drink), name: "Groceries")

      # "Test" category is left un-budgeted (budgeted_spending defaults to 0 after sync_budget_categories)
      create_transaction(account: @account, date: Date.new(2026, 3, 12), amount: 50, category: categories(:one), name: "Misc")

      digest = @family.weekly_spending_digest(end_date: end_date, user: users(:family_admin))
      lines = digest.posted_categories

      expected_weekly_target = (BigDecimal("200") * 7 / 31)
      food_line = lines.find { |l| l.name == "Food & Drink" }
      assert_equal Money.new(expected_weekly_target, "USD"), food_line.weekly_budget
      assert_equal ((40.to_d / expected_weekly_target) * 100).round, food_line.budget_pct
      assert_equal :near, food_line.status

      unbudgeted_line = lines.find { |l| l.name == categories(:one).name }
      assert_nil unbudgeted_line.weekly_budget
      assert_nil unbudgeted_line.budget_pct
      assert_equal :none, unbudgeted_line.status

      # Budgeted categories lead un-budgeted ones regardless of amount.
      assert_equal food_line, lines.first
    end
  end

  test "spend under 80% of weekly target is :under; spend over 100% is :over" do
    travel_to Time.zone.local(2026, 4, 13, 12, 0, 0) do
      end_date = Date.new(2026, 4, 12) # window: Apr 6 - Apr 12 (April has 30 days)

      budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 4, 1))
      food_budget_category = budget.budget_categories.reload.find { |bc| bc.category_id == categories(:food_and_drink).id }
      food_budget_category.update_budgeted_spending!(300)
      one_budget_category = budget.budget_categories.reload.find { |bc| bc.category_id == categories(:one).id }
      one_budget_category.update_budgeted_spending!(100)

      # Food & Drink: weekly target = 300 * 7 / 30 = $70. $20 spend ~= 28.6% -> :under
      create_transaction(account: @account, date: Date.new(2026, 4, 8), amount: 20, category: categories(:food_and_drink), name: "Snacks")

      # "Test": weekly target = 100 * 7 / 30 ~= $23.33. $50 spend ~= 214% -> :over
      create_transaction(account: @account, date: Date.new(2026, 4, 9), amount: 50, category: categories(:one), name: "Gadget")

      digest = @family.weekly_spending_digest(end_date: end_date, user: users(:family_admin))
      lines = digest.posted_categories

      food_target = (BigDecimal("300") * 7 / 30)
      food_line = lines.find { |l| l.name == "Food & Drink" }
      assert_equal Money.new(food_target, "USD"), food_line.weekly_budget
      assert_equal ((20.to_d / food_target) * 100).round, food_line.budget_pct
      assert_equal :under, food_line.status

      one_target = (BigDecimal("100") * 7 / 30)
      one_line = lines.find { |l| l.name == categories(:one).name }
      assert_equal Money.new(one_target, "USD"), one_line.weekly_budget
      assert_equal ((50.to_d / one_target) * 100).round, one_line.budget_pct
      assert_equal :over, one_line.status
    end
  end

  test "no budget covers the window's month -> all categories are :none" do
    travel_to Time.zone.local(2026, 6, 15, 12, 0, 0) do
      end_date = Date.new(2026, 6, 14) # window: Jun 8 - Jun 14; no Budget fixture/bootstrap for June

      create_transaction(account: @account, date: Date.new(2026, 6, 10), amount: 40, category: categories(:food_and_drink), name: "Lunch")
      create_transaction(account: @account, date: Date.new(2026, 6, 11), amount: 60, category: categories(:one), name: "Gear")

      digest = @family.weekly_spending_digest(end_date: end_date, user: users(:family_admin))
      lines = digest.posted_categories

      assert_operator lines.size, :>=, 2
      lines.each do |line|
        assert_equal :none, line.status
        assert_nil line.weekly_budget
        assert_nil line.budget_pct
      end
    end
  end

  test "digest is scoped to accounts the recipient can see" do
    travel_to Time.zone.local(2026, 7, 15, 12, 0, 0) do
      end_date = Date.new(2026, 7, 14)

      # `connected` is owned by family_admin and is NOT shared with family_member
      # (only `depository` and `credit_card` are shared, per account_shares fixtures),
      # so it is invisible in family_member's finances.
      hidden_account = accounts(:connected)
      assert_includes users(:family_admin).finance_accounts.pluck(:id), hidden_account.id
      refute_includes users(:family_member).finance_accounts.pluck(:id), hidden_account.id

      # Spending posted + pending on the account the member cannot see.
      create_transaction(account: hidden_account, date: Date.new(2026, 7, 10), amount: 40, category: categories(:food_and_drink), name: "AdminOnlyPosted")
      pending_entry = create_transaction(account: hidden_account, date: Date.new(2026, 7, 11), amount: 50, category: categories(:food_and_drink), name: "AdminOnlyHold")
      pending_entry.entryable.update!(extra: { "plaid" => { "pending" => true } })

      admin_digest  = @family.weekly_spending_digest(end_date: end_date, user: users(:family_admin))
      member_digest = @family.weekly_spending_digest(end_date: end_date, user: users(:family_member))

      # Owner sees the hidden-account spending; the member's total is lower by at
      # least the hidden posted amount (both share the depository baseline, so the
      # delta isolates exactly the account the member can't see).
      assert_operator admin_digest.posted_total.amount, :>=, 40
      assert_operator admin_digest.posted_total.amount - member_digest.posted_total.amount, :>=, 40

      # Pending is likewise scoped: admin sees the $50 hold, member sees none of it
      # (no baseline pending exists in the window).
      assert_equal Money.new(50, "USD"), admin_digest.pending_total
      assert_equal 0, member_digest.pending_total.amount.to_i
    end
  end
end
