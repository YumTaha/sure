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
      assert_operator digest.mtd_total.amount, :>=, 400             # 200 (yday) + 200 (earlier) + baseline fixture data
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
