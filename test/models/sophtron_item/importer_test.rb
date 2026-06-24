require "test_helper"

class SophtronItem::ImporterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      customer_id: "cust-1",
      user_institution_id: "ui-1"
    )
  end

  test "fetches accounts by stored user institution id" do
    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_created]
    assert_equal "acct-1", @item.sophtron_accounts.first.account_id
  end

  test "missing user institution id fails import and marks item requires update" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)
    @item.update!(user_institution_id: nil, status: :good, last_connection_error: nil)

    provider = mock
    provider.expects(:get_accounts).never

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert_not result[:success]
    assert_equal "Sophtron institution connection is incomplete", result[:error]
    assert_equal "requires_update", @item.reload.status
    assert_equal "Sophtron institution connection is incomplete", @item.last_connection_error
  end

  test "initial linked account import fetches transactions without starting a refresh job" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).never
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [
        {
          id: "tx-1",
          accountId: "acct-1",
          amount: "-12.34",
          currency: "USD",
          date: "2026-05-01",
          merchant: "Coffee Shop",
          description: "Coffee Shop"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal 1, sophtron_account.reload.raw_transactions_payload.count
  end

  test "automatic import skips linked accounts that require manual sync" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      manual_sync: true
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).never
    provider.expects(:get_account_transactions).never

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 0, result[:transactions_imported]
    assert_nil sophtron_account.reload.raw_transactions_payload
  end

  test "later sync fetches transactions for account that had empty initial transaction fetch" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).never
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [],
      total: 0
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    # raw_transactions_payload stays nil so the account can self-heal on a later fetch
    assert_nil sophtron_account.reload.raw_transactions_payload

    # Second import: raw_transactions_payload is still nil so initial_transaction_fetch?
    # remains true — no refresh is triggered, the fetch goes direct and picks up real data.
    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).never
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [
        {
          id: "tx-1",
          accountId: "acct-1",
          amount: "-12.34",
          currency: "USD",
          date: "2026-05-01",
          merchant: "Coffee Shop",
          description: "Coffee Shop"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal 1, sophtron_account.reload.raw_transactions_payload.count
  end

  test "completed item sync with no stored transaction payload refreshes before fetching" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)
    @item.stubs(:last_synced_at).returns(Time.current)

    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).with("acct-1").returns({ JobID: "refresh-job" })
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Completed" })
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [
        {
          id: "tx-1",
          accountId: "acct-1",
          amount: "-12.34",
          currency: "USD",
          date: "2026-05-01",
          merchant: "Coffee Shop",
          description: "Coffee Shop"
        }.with_indifferent_access
      ],
      total: 1
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert result[:success]
    assert_equal 1, sophtron_account.reload.raw_transactions_payload.count
  end

  test "marks item requires update when refresh job requires mfa" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      raw_transactions_payload: [ { id: "existing-tx" } ]
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).with("acct-1").returns({ JobID: "refresh-job" })
    provider.expects(:get_job_information).with("refresh-job").returns({
      SecurityQuestion: [ "Question?" ].to_json,
      LastStatus: "Waiting"
    })

    result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

    assert_not result[:success]
    assert_equal "requires_update", @item.reload.status
    assert_equal "refresh-job", @item.current_job_id
  end

  test "refresh job still running enqueues poll job without fetching transactions" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      raw_transactions_payload: [ { id: "existing-tx" } ]
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          account_id: "acct-1",
          account_name: "Checking",
          balance: "100.00",
          balance_currency: "USD",
          currency: "USD"
        }.with_indifferent_access
      ],
      total: 1
    })
    provider.expects(:refresh_account).with("acct-1").returns({ JobID: "refresh-job" })
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Started" })
    provider.expects(:get_account_transactions).never

    assert_enqueued_with(job: SophtronRefreshPollJob) do
      result = SophtronItem::Importer.new(@item, sophtron_provider: provider).import

      assert result[:success]
      assert_equal 0, result[:transactions_imported]
      assert_equal 0, result[:transactions_failed]
    end
  end

  # When the API returns transactions but ALL are filtered out (e.g. every entry has
  # a blank/missing :id), new_transactions ends up empty. The else-branch must NOT
  # persist existing_transactions (which is []) when raw_transactions_payload is nil —
  # doing so would wedge the account the same way as writing [] from an empty API response.
  test "all-filtered transactions do not persist empty snapshot when raw_transactions_payload is nil" do
    account = accounts(:depository)
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )
    AccountProvider.create!(account: account, provider: sophtron_account)

    # Every transaction is missing :id — all will be filtered out by the dedup logic
    provider = mock
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [
        { accountId: "acct-1", amount: "-10.00", currency: "USD", date: "2026-06-01" }.with_indifferent_access,
        { accountId: "acct-1", amount: "-20.00", currency: "USD", date: "2026-06-02" }.with_indifferent_access
      ],
      total: 2
    })

    # Use import_transactions_after_refresh (refresh: false) to bypass the refresh
    # path and isolate the filtered-out-transactions / empty-snapshot logic.
    result = SophtronItem::Importer.new(@item, sophtron_provider: provider)
                                   .import_transactions_after_refresh(sophtron_account)

    assert result[:success], "expected success: true even when all transactions are filtered"
    assert_equal 2, result[:transactions_count], "transactions_count reflects what the API returned"
    assert_nil sophtron_account.reload.raw_transactions_payload,
               "raw_transactions_payload must stay nil — persisting [] would wedge the account"
  end

  # Sophtron vendor lag fix: empty transaction response must NOT persist [] snapshot.
  # Storing [] would flip raw_transactions_payload from nil to non-nil, permanently
  # wedging initial_transaction_fetch? to false and making the account unable to
  # self-heal when real transactions are available on the next fetch.
  test "fetch_and_store_transactions with empty response leaves raw_transactions_payload nil" do
    sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100
    )

    provider = mock
    provider.expects(:get_account_transactions).with("acct-1", start_date: anything).returns({
      transactions: [],
      total: 0
    })

    # Use import_transactions_after_refresh (refresh: false) so we bypass the
    # refresh path and go straight to the fetch, isolating the empty-snapshot logic.
    result = SophtronItem::Importer.new(@item, sophtron_provider: provider)
                                   .import_transactions_after_refresh(sophtron_account)

    assert result[:success], "expected success: true for empty fetch"
    assert_equal 0, result[:transactions_count]
    assert_nil sophtron_account.reload.raw_transactions_payload,
               "raw_transactions_payload must stay nil — [] would wedge the account"
  end
end
