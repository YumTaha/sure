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
    body = email.body.encoded
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
    assert_match(/\$0/, email.body.encoded)
  end
end
