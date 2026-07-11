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

      digest = @family.weekly_spending_digest(end_date: end_date)

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

      # Sorted descending by amount
      assert_equal categories.map { |c| c.amount.amount }, categories.map { |c| c.amount.amount }.sort.reverse

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
      digest = families(:empty).weekly_spending_digest(end_date: Date.new(2026, 7, 14))
      assert_equal 0, digest.posted_total.amount.to_i
      assert_equal 0, digest.pending_total.amount.to_i
      assert_equal 0, digest.estimated_total.amount.to_i
      assert_empty digest.posted_categories
    end
  end
end
