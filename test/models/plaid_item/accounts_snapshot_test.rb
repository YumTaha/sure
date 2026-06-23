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
    @plaid_item.update!(available_products: [ "liabilities" ], billed_products: [],
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
    @plaid_item.update!(available_products: [ "liabilities" ], billed_products: [])

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
end
