require "test_helper"

class PlaidItem::AccountsSnapshotTest < ActiveSupport::TestCase
  setup do
    @plaid_item = plaid_items(:one)
    @plaid_item.plaid_accounts.destroy_all # Clean slate

    @plaid_provider = mock
    @snapshot = PlaidItem::AccountsSnapshot.new(@plaid_item, plaid_provider: @plaid_provider)
  end

  test "fetches accounts" do
    @plaid_provider.expects(:get_item_accounts).with(@plaid_item.access_token).returns(
      OpenStruct.new(accounts: [])
    )
    @snapshot.accounts
  end

  test "leaves out accounts that report no balance" do
    card = OpenStruct.new(
      account_id: "card",
      type: "credit",
      subtype: "credit card",
      balances: OpenStruct.new(current: 120.5, available: nil)
    )
    bill_pay = OpenStruct.new(
      account_id: "bill_pay",
      type: "depository",
      subtype: "checking",
      balances: OpenStruct.new(current: nil, available: nil)
    )
    @plaid_provider.expects(:get_item_accounts).with(@plaid_item.access_token).returns(
      OpenStruct.new(accounts: [ card, bill_pay ])
    ).once

    assert_difference -> { DebugLogEntry.where(source: "PlaidItem::AccountsSnapshot").count }, 1 do
      assert_equal [ "card" ], @snapshot.accounts.map(&:account_id)
      assert_equal [ "card" ], @snapshot.accounts.map(&:account_id)
    end
  end

  test "keeps an already imported account that reports no balance" do
    @plaid_item.plaid_accounts.create!(
      plaid_id: "card",
      name: "Card",
      plaid_type: "credit",
      currency: "USD",
      current_balance: 120.5
    )
    card = OpenStruct.new(
      account_id: "card",
      type: "credit",
      subtype: "credit card",
      balances: OpenStruct.new(current: nil, available: nil)
    )
    @plaid_provider.expects(:get_item_accounts).with(@plaid_item.access_token).returns(
      OpenStruct.new(accounts: [ card ])
    ).once

    assert_no_difference -> { DebugLogEntry.count } do
      assert_equal [ "card" ], @snapshot.accounts.map(&:account_id)
    end
  end

  test "fetches transactions data if item supports transactions and any accounts present" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "depository"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: nil).returns(
      OpenStruct.new(
        added: [],
        modified: [],
        removed: [],
        cursor: "test_cursor_1"
      )
    ).once
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "does not fetch transactions if no accounts" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [])

    @snapshot.expects(:accounts).returns([]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "updates next_cursor when fetching transactions" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [], next_cursor: "test_cursor_1")

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "depository"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: "test_cursor_1").returns(
      OpenStruct.new(
        added: [],
        modified: [],
        removed: [],
        cursor: "test_cursor_2"
      )
    ).once

    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "fetches investments data if item supports investments and investment accounts present" do
    # Restrict consent to investments only so transactions gate stays closed
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [],
                        raw_payload: { "consented_products" => [ "investments" ] })

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "investment"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).with(@plaid_item.access_token).once
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "keeps securities for an investment account with holdings but no investment transactions" do
    # Restrict consent to investments only so transactions gate stays closed
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [],
                        raw_payload: { "consented_products" => [ "investments" ] })
    @snapshot.stubs(:accounts).returns([ OpenStruct.new(account_id: "123", type: "investment") ])

    security = OpenStruct.new(security_id: "sec_1", ticker_symbol: "VTI")
    @plaid_provider.expects(:get_item_investments).with(@plaid_item.access_token).returns(
      OpenStruct.new(
        holdings: [ OpenStruct.new(account_id: "123", security_id: "sec_1") ],
        transactions: [],
        securities: [ security ]
      )
    )

    investments = @snapshot.get_account_data("123").investments_data

    assert_equal [ "sec_1" ], investments.holdings.map(&:security_id)
    assert_equal [ security ], investments.securities
  end

  test "has no securities for an investment account with neither holdings nor transactions" do
    # Restrict consent to investments only so transactions gate stays closed
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [],
                        raw_payload: { "consented_products" => [ "investments" ] })
    @snapshot.stubs(:accounts).returns([ OpenStruct.new(account_id: "123", type: "investment") ])

    @plaid_provider.expects(:get_item_investments).with(@plaid_item.access_token).returns(
      OpenStruct.new(
        holdings: [ OpenStruct.new(account_id: "other", security_id: "sec_1") ],
        transactions: [],
        securities: [ OpenStruct.new(security_id: "sec_1") ]
      )
    )

    assert_empty @snapshot.get_account_data("123").investments_data.securities
  end

  test "does not fetch investments if no investment accounts" do
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [])

    @snapshot.expects(:accounts).returns([]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  test "fetches liabilities data if item supports liabilities and liabilities accounts present" do
    # Restrict consent to liabilities only so transactions gate stays closed
    @plaid_item.update!(available_products: [], billed_products: [ "liabilities" ],
                        raw_payload: { "consented_products" => [ "liabilities" ] })

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "loan",
        subtype: "student"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).with(@plaid_item.access_token).once

    @snapshot.get_account_data("123")
  end

  test "does not fetch liabilities if no liabilities accounts" do
    @plaid_item.update!(available_products: [], billed_products: [ "liabilities" ])

    @snapshot.expects(:accounts).returns([]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end

  # ── consented-but-unbilled product gates ─────────────────────────────────

  test "fetches transactions when product is consented but not billed or available" do
    # transactions NOT in available_products or billed_products, but IS consented (non-EU item defaults to all)
    @plaid_item.update!(available_products: [], billed_products: [], plaid_region: "us", raw_payload: {})

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "abc", type: "depository")
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: nil).returns(
      OpenStruct.new(added: [], modified: [], removed: [], cursor: nil)
    ).once
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("abc")
  end

  test "does not fetch transactions when product is neither supported nor consented" do
    # Snapshot explicitly lists only investments as consented — transactions absent
    @plaid_item.update!(available_products: [], billed_products: [], plaid_region: "us",
                        raw_payload: { "consented_products" => [ "investments" ] })

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "abc", type: "depository")
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("abc")
  end

  # ── transient "product not ready" error handling (E2) ────────────────────

  test "transactions_data returns nil when Plaid raises PRODUCT_NOT_READY" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "abc", type: "depository")
    ]).at_least_once

    plaid_error = Plaid::ApiError.new(
      code: 400,
      response_body: { "error_code" => "PRODUCT_NOT_READY", "error_message" => "Product not initialized yet" }.to_json
    )
    @plaid_provider.expects(:get_transactions).raises(plaid_error)

    # Must NOT raise, must return nil so the product is skipped this sync
    assert_nil @snapshot.send(:transactions_data)
  end

  test "investments_data returns nil when Plaid raises PRODUCT_NOT_READY" do
    @plaid_item.update!(available_products: [ "investments" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "abc", type: "investment")
    ]).at_least_once

    plaid_error = Plaid::ApiError.new(
      code: 400,
      response_body: { "error_code" => "PRODUCT_NOT_READY", "error_message" => "Product not initialized yet" }.to_json
    )
    @plaid_provider.expects(:get_item_investments).raises(plaid_error)

    assert_nil @snapshot.send(:investments_data)
  end

  test "liabilities_data returns nil when Plaid raises PRODUCTS_NOT_SUPPORTED" do
    @plaid_item.update!(available_products: [ "liabilities" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "abc", type: "credit", subtype: "credit card")
    ]).at_least_once

    plaid_error = Plaid::ApiError.new(
      code: 400,
      response_body: { "error_code" => "PRODUCTS_NOT_SUPPORTED", "error_message" => "Not supported" }.to_json
    )
    @plaid_provider.expects(:get_item_liabilities).raises(plaid_error)

    assert_nil @snapshot.send(:liabilities_data)
  end

  test "transactions_data nil is memoized — fetch runs only once on transient error across multiple calls" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "abc", type: "depository")
    ]).at_least_once

    plaid_error = Plaid::ApiError.new(
      code: 400,
      response_body: { "error_code" => "PRODUCT_NOT_READY", "error_message" => "Product not initialized yet" }.to_json
    )
    # .once proves the second call hits the memoized nil and does NOT re-call the provider
    @plaid_provider.expects(:get_transactions).once.raises(plaid_error)

    first_result  = @snapshot.send(:transactions_data)
    second_result = @snapshot.send(:transactions_data)

    assert_nil first_result,  "expected first call to return nil on transient error"
    assert_nil second_result, "expected second call to return memoized nil without re-fetching"
    # mocha verifies :get_transactions was called exactly once (no extra call on second invocation)
  end

  test "non-transient Plaid errors are re-raised, not swallowed" do
    @plaid_item.update!(available_products: [ "transactions" ], billed_products: [])

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "abc", type: "depository")
    ]).at_least_once

    real_error = Plaid::ApiError.new(
      code: 500,
      response_body: { "error_code" => "INTERNAL_SERVER_ERROR", "error_message" => "Something broke" }.to_json
    )
    @plaid_provider.expects(:get_transactions).raises(real_error)

    assert_raises(Plaid::ApiError) { @snapshot.send(:transactions_data) }
  end

  test "fetches liabilities for a credit account when liabilities was an additionally consented product" do
    @plaid_item.update!(
      available_products: [],
      billed_products: [],
      raw_payload: { "consented_products" => [ "liabilities" ] }
    )

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "credit",
        subtype: "credit card"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).never
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).with(@plaid_item.access_token).once

    @snapshot.get_account_data("123")
  end

  test "skips liabilities the institution does not support without failing the sync" do
    # A Credit Card link asks for liabilities as an optional product, and Link
    # records the consent even when the issuer lacks it (e.g. Bilt Rewards).
    @plaid_item.update!(
      available_products: [],
      billed_products: [ "transactions" ],
      raw_payload: { "consented_products" => [ "transactions", "liabilities" ] }
    )

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "123", type: "credit", subtype: "credit card"),
      OpenStruct.new(account_id: "456", type: "credit", subtype: "credit card")
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: nil).returns(
      OpenStruct.new(
        added: [],
        modified: [],
        removed: [],
        cursor: "test_cursor_1"
      )
    ).once
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).with(@plaid_item.access_token).raises(
      Plaid::ApiError.new(code: 400, response_body: { "error_code" => "PRODUCTS_NOT_SUPPORTED" }.to_json)
    ).once

    assert_difference -> { DebugLogEntry.where(source: "PlaidItem::AccountsSnapshot").count }, 1 do
      assert_nil @snapshot.get_account_data("123").liabilities_data
      assert_nil @snapshot.get_account_data("456").liabilities_data
    end
  end

  test "still raises other liabilities errors" do
    # Restrict consent to liabilities only so transactions gate stays closed
    @plaid_item.update!(available_products: [], billed_products: [ "liabilities" ],
                        raw_payload: { "consented_products" => [ "liabilities" ] })

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(account_id: "123", type: "credit", subtype: "credit card")
    ]).at_least_once

    @plaid_provider.expects(:get_item_liabilities).raises(
      Plaid::ApiError.new(code: 400, response_body: { "error_code" => "ITEM_LOGIN_REQUIRED" }.to_json)
    )

    assert_raises(Plaid::ApiError) { @snapshot.get_account_data("123") }
  end

  test "skips optional liabilities the user did not grant" do
    # With liabilities optional, Plaid still creates the Item when the user
    # withholds the OAuth permission, and /liabilities/get then fails.
    @plaid_item.update!(
      available_products: [],
      billed_products: [ "transactions" ],
      raw_payload: { "consented_products" => [ "transactions", "liabilities" ] }
    )

    %w[ACCESS_NOT_GRANTED NO_LIABILITY_ACCOUNTS].each do |error_code|
      provider = mock
      snapshot = PlaidItem::AccountsSnapshot.new(@plaid_item, plaid_provider: provider)
      snapshot.expects(:accounts).returns([
        OpenStruct.new(account_id: "123", type: "credit", subtype: "credit card")
      ]).at_least_once
      provider.expects(:get_transactions).returns(
        OpenStruct.new(added: [], modified: [], removed: [], cursor: "test_cursor_1")
      )
      provider.expects(:get_item_liabilities).raises(
        Plaid::ApiError.new(code: 400, response_body: { "error_code" => error_code }.to_json)
      ).once

      assert_difference -> { DebugLogEntry.where(source: "PlaidItem::AccountsSnapshot").count }, 1 do
        assert_nil snapshot.get_account_data("123").liabilities_data
      end
    end
  end

  test "still raises unavailable-liabilities errors once liabilities was added to the item" do
    # Restrict consent to liabilities only so transactions gate stays closed
    @plaid_item.update!(available_products: [], billed_products: [ "liabilities" ],
                        raw_payload: { "consented_products" => [ "liabilities" ] })

    %w[PRODUCTS_NOT_SUPPORTED ACCESS_NOT_GRANTED NO_LIABILITY_ACCOUNTS].each do |error_code|
      provider = mock
      snapshot = PlaidItem::AccountsSnapshot.new(@plaid_item, plaid_provider: provider)
      snapshot.expects(:accounts).returns([
        OpenStruct.new(account_id: "123", type: "loan", subtype: "student")
      ]).at_least_once
      provider.expects(:get_item_liabilities).raises(
        Plaid::ApiError.new(code: 400, response_body: { "error_code" => error_code }.to_json)
      )

      assert_raises(Plaid::ApiError) { snapshot.get_account_data("123") }
    end
  end

  test "does not fetch liabilities the institution offers but the user did not consent to" do
    # A Depository link consents to transactions and investments only. Plaid
    # still lists liabilities in available_products when the institution
    # offers it, but /liabilities/get then fails with ADDITIONAL_CONSENT_REQUIRED.
    @plaid_item.update!(
      available_products: [ "liabilities" ],
      billed_products: [ "transactions" ],
      raw_payload: { "consented_products" => [ "transactions", "investments" ] }
    )

    @snapshot.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "123",
        type: "credit",
        subtype: "credit card"
      )
    ]).at_least_once

    @plaid_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: nil).returns(
      OpenStruct.new(
        added: [],
        modified: [],
        removed: [],
        cursor: "test_cursor_1"
      )
    ).once
    @plaid_provider.expects(:get_item_investments).never
    @plaid_provider.expects(:get_item_liabilities).never

    @snapshot.get_account_data("123")
  end
end
