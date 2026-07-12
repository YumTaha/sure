require "test_helper"
require "ostruct"

class SpendingDigestMailerTest < ActionMailer::TestCase
  test "weekly email addresses the user and shows totals + categories" do
    user = users(:family_admin)
    digest = OpenStruct.new(
      posted_total: Money.new(200, "USD"),
      pending_total: Money.new(50, "USD"),
      estimated_total: Money.new(250, "USD"),
      currency: "USD",
      range_label: "Jul 8 – Jul 14, 2026",
      posted_categories: [
        Family::WeeklySpendingDigest::CategoryLine.new(name: "Food & Drink", amount: Money.new(100, "USD"), pct: 50, weekly_budget: Money.new(200, "USD"), budget_pct: 50, status: :under),
        Family::WeeklySpendingDigest::CategoryLine.new(name: "Shopping", amount: Money.new(100, "USD"), pct: 50, weekly_budget: nil, budget_pct: nil, status: :none)
      ]
    )

    email = SpendingDigestMailer.with(user: user, digest: digest).weekly

    assert_equal [ user.email ], email.to
    assert_match(/spent/i, email.subject)
    body = email.body.encoded
    assert_includes body, "Food & Drink"
    assert_includes body, "Shopping"
    assert_includes body, "Pending"
  end

  test "zero-spend renders cleanly" do
    user = users(:family_admin)
    digest = OpenStruct.new(
      posted_total: Money.new(0, "USD"),
      pending_total: Money.new(0, "USD"),
      estimated_total: Money.new(0, "USD"),
      currency: "USD",
      range_label: "Jul 8 – Jul 14, 2026",
      posted_categories: []
    )
    email = SpendingDigestMailer.with(user: user, digest: digest).weekly
    assert_equal [ user.email ], email.to
    assert_match(/\$0/, email.body.encoded)
  end
end
