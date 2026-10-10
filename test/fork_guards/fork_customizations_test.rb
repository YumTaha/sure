require "test_helper"

# FORK CUSTOMIZATION GUARD -- protects this fork's deliberate divergences.
#
# Upstream has twice reverted one of our changes WITHOUT producing a merge
# conflict (2026-09-09: the Plaid credit-card billing, and the sync-cancel
# ordering fix, which came back as a clean non-conflict because the code moved
# into a new partial). Upstream's own test suite cannot protect us: it is
# updated to match upstream's behavior, so CI goes green on a regression of
# ours.
#
# These tests make our invariants executable, so a silent revert fails the
# build instead of reaching production. If one fails after an upstream sync,
# the fix is almost always to re-apply our change -- not to relax the test.
class ForkCustomizationsTest < ActiveSupport::TestCase
  # Plaid's client needs a real config object; region drives the EU branch.
  def plaid_for(region)
    Provider::Plaid.new(Plaid::Configuration.new, region: region)
  end

  # --- Plaid: never force a re-link (the hard rule) -------------------------
  # Plaid's free tier caps connections, not API calls, and an Item's billed
  # products are frozen at link time. Credit cards must bill `transactions`
  # alongside `liabilities` or transaction history silently stops syncing on
  # Amex/Discover -- invisible for weeks. See LESSONS.md "PLAID no re-link".
  test "credit cards and loans still bill liabilities AND transactions" do
    plaid = plaid_for(:us)

    %w[CreditCard Loan].each do |type|
      products = plaid.send(:get_initial_products, type)
      assert_includes products, "liabilities", "#{type} must bill liabilities"
      assert_includes products, "transactions",
        "#{type} must bill transactions, or can_fetch_transactions? is false and history stops syncing"
    end
  end

  test "investment links still bill investments, and EU stays transactions-only" do
    us = plaid_for(:us)
    assert_equal [ "investments" ], us.send(:get_initial_products, "Investment")

    eu = plaid_for(:eu)
    assert_equal [ "transactions" ], eu.send(:get_initial_products, "CreditCard")
  end

  # Upstream's rule, kept deliberately: requesting `liabilities` on a
  # non-liability link makes Plaid Link hide investment-only brokerages.
  test "liabilities is not consented for non-liability account types" do
    plaid = plaid_for(:us)
    assert_not_includes plaid.send(:get_additional_consented_products, "Investment"), "liabilities"
  end

  # --- Weekly spending digest (ours, PR #13/#14/#16) ------------------------
  test "the weekly digest cron entry survives, with active_job set" do
    schedule = YAML.safe_load_file(Rails.root.join("config/schedule.yml"))
    entry = schedule["weekly_spending_digest"]

    assert entry, "weekly_spending_digest disappeared from config/schedule.yml"
    assert_equal "WeeklySpendingDigestJob", entry["class"]
    assert_equal "scheduled", entry["queue"]
    # Without this, a tick from a process that cannot resolve the class pushes a
    # raw Sidekiq payload and the worker dies on `undefined method 'jid='`.
    assert_equal true, entry["active_job"]
  end

  test "the digest's per-family send marker column survives" do
    assert_includes Family.column_names, "last_weekly_digest_sent_on"
  end

  # Security-audit fix (PR #16): the digest must be scoped to ONE user, never
  # aggregate every account in the family into one mail.
  test "the digest is still per-user scoped, not family-wide" do
    assert_equal %i[user], Family::WeeklySpendingDigest.instance_method(:initialize)
      .parameters.select { |type, _| type == :keyreq }.map(&:last) - [ :end_date ]
  end

  # --- AI chat (ours, PR #1) ------------------------------------------------
  test "a streaming assistant turn claims as generating, not complete" do
    assert_includes Message.statuses.keys, "generating",
      "the `generating` status backs our composer send-lock"

    source = Rails.root.join("app/models/assistant_message.rb").read
    assert_match(/update_all\(status: "generating"\)/, source,
      "append_text! must claim the row as `generating`; claiming `complete` releases the " \
      "send-lock mid-turn and lets a second message be sent while the model is still streaming")
  end

  # --- Sync cancel (ours, PR #19) -------------------------------------------
  # Reverted once already by an upstream refactor that moved this markup into a
  # new partial, with no conflict raised.
  test "the cancel-sync button targets a deterministic sync" do
    source = Rails.root.join("app/views/accounts/_sync_controls.html.erb").read
    assert_match(/syncs\.visible\.ordered\.first/, source,
      "unordered .visible.first lets the button cancel an arbitrary sync when several are live")
  end

  # --- Sophtron (connection retired 2026-10-10; code deliberately retained) --
  test "the Sophtron remote-disconnect path is still present" do
    assert SophtronItem.instance_methods.include?(:delete_remote!),
      "delete_remote! is called from sophtron_items_controller and prevents orphaned " \
      "remote UserInstitutions. Keep it even though the connection is retired."
  end

  # --- Security: CVE floors we hold ahead of upstream -----------------------
  # Upstream has rolled these BACK on us before (2026-09-09). sidekiq-cron
  # matters more now that upstream mounts the Sidekiq Web UI in production.
  test "gems we hold ahead of upstream for CVEs do not regress" do
    floors = {
      "oauth2" => "2.0.25",       # GHSA-pp92-crg2-gfv9, HIGH: bearer leak via redirect
      "sidekiq-cron" => "2.4.0",  # CVE-2025-67202, web UI XSS
      "msgpack" => "1.8.2"
    }
    lock = File.read(Rails.root.join("Gemfile.lock"))

    floors.each do |gem, floor|
      found = lock[/^    #{Regexp.escape(gem)} \(([^)]+)\)/, 1]
      assert found, "#{gem} missing from Gemfile.lock"
      assert Gem::Version.new(found) >= Gem::Version.new(floor),
        "#{gem} regressed to #{found}, below our #{floor} CVE floor. An upstream sync most " \
        "likely reset it -- re-apply with `bundle lock --conservative --update=#{gem}`."
    end
  end
end
