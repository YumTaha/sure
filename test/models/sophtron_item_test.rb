require "test_helper"

class SophtronItemTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key")
    )
  end

  test "ensure_customer reuses persisted customer id" do
    @item.update!(customer_id: "cust-existing")
    provider = mock
    provider.expects(:list_customers).never

    assert_equal "cust-existing", @item.ensure_customer!(provider: provider)
  end

  test "ensure_customer reuses matching listed customer" do
    provider = mock
    provider.expects(:list_customers).returns([
      { CustomerID: "cust-1", CustomerName: @item.generated_customer_name }
    ])
    provider.expects(:create_customer).never

    assert_equal "cust-1", @item.ensure_customer!(provider: provider)
    assert_equal "cust-1", @item.customer_id
    assert_equal @item.generated_customer_name, @item.customer_name
  end

  test "ensure_customer creates customer when no matching customer exists" do
    provider = mock
    provider.expects(:list_customers).returns([])
    provider.expects(:create_customer)
      .with(unique_id: @item.generated_customer_unique_id, name: @item.generated_customer_name, source: "Sure")
      .returns({ CustomerID: "cust-new", CustomerName: @item.generated_customer_name })

    assert_equal "cust-new", @item.ensure_customer!(provider: provider)
    assert_equal "cust-new", @item.customer_id
  end

  test "connected_to_institution ignores failed connection attempts" do
    @item.update!(user_institution_id: "ui-1", status: :requires_update)

    assert_not @item.connected_to_institution?
  end

  test "connected_to_institution ignores jobs that are still running" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1", status: :good)

    assert_not @item.connected_to_institution?
  end

  test "connected_to_institution ignores stale timeout job snapshots" do
    @item.update!(
      user_institution_id: "ui-1",
      status: :good,
      job_status: "Timeout",
      raw_job_payload: {
        SuccessFlag: false,
        LastStatus: "Timeout"
      }
    )

    assert_not @item.connected_to_institution?
  end

  test "provider_display_name keeps accounts grouping provider-level" do
    @item.update!(name: "Bank of America", institution_name: "Bank of America")

    assert_equal "Sophtron Connection", @item.provider_display_name
  end

  test "fetch_remote_accounts persists Sophtron account snapshots" do
    @item.update!(user_institution_id: "ui-1")
    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          id: "acct-1",
          account_id: "acct-1",
          account_name: "Sophtron Checking",
          balance: "123.45",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    @item.stubs(:sophtron_provider).returns(provider)

    accounts = @item.fetch_remote_accounts(force: true)

    assert_equal 1, accounts.count
    assert_equal "Sophtron Checking", @item.sophtron_accounts.find_by!(account_id: "acct-1").name
  end

  test "reject_already_linked removes accounts with existing account provider links" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Sophtron Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    available = @item.reject_already_linked([
      { id: "acct-1", account_name: "Linked" },
      { id: "acct-2", account_name: "Available" }
    ])

    assert_equal [ "acct-2" ], available.map { |account_data| SophtronItem.external_account_id(account_data) }
  end

  test "build_mfa_challenge normalizes Sophtron job challenge fields" do
    challenge = @item.build_mfa_challenge(
      SecurityQuestion: [ "Question?" ].to_json,
      TokenMethod: [ "sms" ].to_json,
      TokenSentFlag: true,
      TokenInputName: "Token",
      TokenRead: "phone",
      CaptchaImage: "YWJj"
    )

    assert_equal [ "Question?" ], challenge[:security_questions]
    assert_equal [ "sms" ], challenge[:token_methods]
    assert_equal true, challenge[:token_sent]
    assert_equal "phone", challenge[:token_read]
    assert_equal "YWJj", challenge[:captcha_image]
  end

  test "start_initial_load_later starts a sync when no active sync exists" do
    assert_no_enqueued_jobs only: SophtronInitialLoadJob do
      assert_difference "@item.syncs.count", 1 do
        assert_enqueued_with job: SyncJob do
          @item.start_initial_load_later
        end
      end
    end
  end

  test "start_initial_load_later seeds sync window for transaction import" do
    @item.update!(sync_start_date: Date.new(2026, 1, 1))

    @item.start_initial_load_later

    assert_equal Date.new(2026, 1, 1), @item.syncs.ordered.first.window_start_date
  end

  test "start_initial_load_later queues a follow-up when current sync is already running" do
    sync = @item.syncs.create!
    sync.start!

    assert_no_difference "@item.syncs.count" do
      assert_enqueued_with job: SophtronInitialLoadJob do
        @item.start_initial_load_later
      end
    end
  end
  test "manual Sophtron accounts do not remove the whole item from automatic sync scope" do
    manual_item = @family.sophtron_items.create!(
      name: "Manual Sophtron",
      user_id: "manual-user",
      access_key: Base64.strict_encode64("secret-key")
    )
    manual_account = manual_item.sophtron_accounts.create!(
      account_id: "acct-manual",
      name: "Manual Sophtron Checking",
      currency: "USD",
      balance: 100,
      manual_sync: true
    )
    auto_account = manual_item.sophtron_accounts.create!(
      account_id: "acct-auto",
      name: "Automatic Sophtron Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: accounts(:depository), provider: manual_account)
    AccountProvider.create!(account: accounts(:credit_card), provider: auto_account)

    assert_includes SophtronItem.active, manual_item
    assert_includes SophtronItem.syncable, manual_item
    assert_equal [ auto_account ], manual_item.automatic_sync_sophtron_accounts.to_a
    assert_equal [ manual_account ], manual_item.manual_sync_sophtron_accounts.to_a
  end

  test "whole item manual mode removes linked accounts from automatic sync scope" do
    manual_item = @family.sophtron_items.create!(
      name: "Manual Sophtron",
      user_id: "manual-user",
      access_key: Base64.strict_encode64("secret-key"),
      manual_sync: true
    )
    first_account = manual_item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Manual Sophtron Checking",
      currency: "USD",
      balance: 100
    )
    second_account = manual_item.sophtron_accounts.create!(
      account_id: "acct-2",
      name: "Manual Sophtron Card",
      currency: "USD",
      balance: 200
    )
    AccountProvider.create!(account: accounts(:depository), provider: first_account)
    AccountProvider.create!(account: accounts(:credit_card), provider: second_account)

    assert_empty manual_item.automatic_sync_sophtron_accounts
    assert_equal [ first_account, second_account ], manual_item.manual_sync_sophtron_accounts.to_a
  end

  test "delete_remote! calls delete_user_institution with item's user_institution_id" do
    @item.update!(user_institution_id: "ui-to-delete")
    provider = mock
    provider.expects(:delete_user_institution).with("ui-to-delete").returns({})
    @item.stubs(:sophtron_provider).returns(provider)

    assert_nothing_raised { @item.delete_remote! }
  end

  test "delete_remote! is a no-op when user_institution_id is blank" do
    @item.update!(user_institution_id: nil)
    provider = mock
    provider.expects(:delete_user_institution).never
    @item.stubs(:sophtron_provider).returns(provider)

    assert_nothing_raised { @item.delete_remote! }
  end

  # Phase 1 full-history: initial_load_window_start_date should use the full history
  # window (MAX_TRANSACTION_HISTORY_YEARS back) so that CreateUserInstitutionWithFullHistory
  # actually fetches all available history, not just the old 120-day default.
  test "initial_load_window_start_date defaults to max history window not 120 days" do
    # No sync_start_date configured — should default to MAX_TRANSACTION_HISTORY_YEARS
    expected = SophtronItem::MAX_TRANSACTION_HISTORY_YEARS.years.ago.to_date
    narrow   = SophtronItem::INITIAL_LOAD_LOOKBACK_DAYS.days.ago.to_date

    result = @item.initial_load_window_start_date

    assert_equal expected, result,
                 "expected full history start #{expected}, got #{result}"
    assert result < narrow,
           "initial load window #{result} must be earlier than the old narrow #{narrow}"
  end

  test "initial_load_window_start_date honours configured sync_start_date" do
    configured = 1.year.ago.to_date
    @item.update!(sync_start_date: configured)
    max_history = SophtronItem::MAX_TRANSACTION_HISTORY_YEARS.years.ago.to_date

    result = @item.initial_load_window_start_date

    # [ configured || max_history, max_history ].max — configured is more recent than
    # max_history so it wins.
    assert_equal [ configured, max_history ].max, result
  end

  test "delete_remote! records a DebugLogEntry and does not raise when provider call fails" do
    @item.update!(user_institution_id: "ui-bad")
    provider = mock
    provider.expects(:delete_user_institution).with("ui-bad").raises(Provider::Sophtron::Error.new("timeout", :request_failed))
    @item.stubs(:sophtron_provider).returns(provider)

    assert_difference "DebugLogEntry.count", 1 do
      assert_nothing_raised { @item.delete_remote! }
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_disconnect", entry.category
    assert_equal "warn", entry.level
    assert_equal "sophtron", entry.provider_key
    assert_equal @item.family, entry.family
    assert_equal "ui-bad", entry.metadata["user_institution_id"]
  end
end
