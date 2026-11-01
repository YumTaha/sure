# All Plaid data is fetched at the item-level.  This class is a simple wrapper that
# providers a convenience method, get_account_data which scopes the item-level payload
# to each Plaid Account
class PlaidItem::AccountsSnapshot
  def initialize(plaid_item, plaid_provider:)
    @plaid_item = plaid_item
    @plaid_provider = plaid_provider
  end

  # Plaid reports no balance at all for some payment-only accounts, such as
  # limited purpose or bill pay accounts that the user can't deselect in Link.
  # PlaidAccount requires a balance and there is nothing to show for them, so
  # new ones are left out instead of failing the whole item import. Accounts
  # already imported stay in: a missing balance there still fails the sync
  # rather than leaving the stored balance and transactions silently stale.
  def accounts
    @accounts ||= begin
      imported = plaid_item.plaid_accounts.pluck(:plaid_id)

      plaid_provider.get_item_accounts(plaid_item.access_token).accounts.select do |account|
        next true if imported.include?(account.account_id)
        next true if account.balances&.current.present? || account.balances&.available.present?

        log_account_without_balance(account)
        false
      end
    end
  end

  def get_account_data(account_id)
    AccountData.new(
      account_data: accounts.find { |a| a.account_id == account_id },
      transactions_data: account_scoped_transactions_data(account_id),
      investments_data: account_scoped_investments_data(account_id),
      liabilities_data: account_scoped_liabilities_data(account_id)
    )
  end

  def transactions_cursor
    return nil unless transactions_data
    transactions_data.cursor
  end

  private
    attr_reader :plaid_item, :plaid_provider

    TransactionsData = Data.define(:added, :modified, :removed)
    LiabilitiesData = Data.define(:credit, :mortgage, :student)
    InvestmentsData = Data.define(:transactions, :holdings, :securities)
    AccountData = Data.define(:account_data, :transactions_data, :investments_data, :liabilities_data)

    def account_scoped_transactions_data(account_id)
      return nil unless transactions_data

      TransactionsData.new(
        added: transactions_data.added.select { |t| t.account_id == account_id },
        modified: transactions_data.modified.select { |t| t.account_id == account_id },
        removed: transactions_data.removed.select { |t| t.account_id == account_id }
      )
    end

    def account_scoped_investments_data(account_id)
      return nil unless investments_data

      transactions = investments_data.transactions.select { |t| t.account_id == account_id }
      holdings = investments_data.holdings.select { |h| h.account_id == account_id }
      # Holdings and investment transactions each resolve their security_id
      # through this metadata, so either one needs it; an account with holdings
      # but no investment transactions is common.
      securities = transactions.any? || holdings.any? ? investments_data.securities : []

      InvestmentsData.new(
        transactions: transactions,
        holdings: holdings,
        securities: securities
      )
    end

    def account_scoped_liabilities_data(account_id)
      return nil unless liabilities_data

      LiabilitiesData.new(
        credit: liabilities_data.credit&.find { |c| c.account_id == account_id },
        mortgage: liabilities_data.mortgage&.find { |m| m.account_id == account_id },
        student: liabilities_data.student&.find { |s| s.account_id == account_id }
      )
    end

    def can_fetch_transactions?
      (plaid_item.supports_product?("transactions") || plaid_item.consents_to_product?("transactions")) && accounts.any?
    end

    # Plaid error codes that mean "this product hasn't finished initializing yet".
    # The first fetch of a newly-consented product can hit one of these codes;
    # Plaid initializes the product asynchronously so the next sync will succeed.
    TRANSIENT_PRODUCT_ERROR_CODES = %w[PRODUCT_NOT_READY PRODUCTS_NOT_SUPPORTED].freeze

    def transactions_data
      return nil unless can_fetch_transactions?
      return @transactions_data if defined?(@transactions_data)

      @transactions_data = fetch_product_data("transactions") do
        plaid_provider.get_transactions(
          plaid_item.access_token,
          next_cursor: plaid_item.next_cursor
        )
      end
    end

    def can_fetch_investments?
      (plaid_item.supports_product?("investments") || plaid_item.consents_to_product?("investments")) &&
      accounts.any? { |a| a.type == "investment" }
    end

    def investments_data
      return nil unless can_fetch_investments?
      return @investments_data if defined?(@investments_data)

      @investments_data = fetch_product_data("investments") do
        plaid_provider.get_item_investments(plaid_item.access_token)
      end
    end

    # Not supports_product?: available_products only says the institution offers
    # liabilities, and fetching it without consent fails the whole sync with
    # ADDITIONAL_CONSENT_REQUIRED. consents_to_product? keeps the fork's fallback
    # for items whose snapshot doesn't record consent, so no re-link is needed.
    def can_fetch_liabilities?
      (plaid_item.consented_to_product?("liabilities") || plaid_item.consents_to_product?("liabilities")) &&
      accounts.any? do |a|
        # Plaid's `credit` type has two subtypes: "credit card" and "paypal".
        # Liabilities covers both, so match on the type rather than allow-listing
        # a single subtype -- otherwise a PayPal Credit account leaves
        # `liabilities` in billed_products (i.e. billed) but never fetched.
        a.type == "credit" ||
        a.type == "loan" && (a.subtype == "mortgage" || a.subtype == "student")
      end
    end

    def liabilities_data
      return @liabilities_data if defined?(@liabilities_data)
      return nil unless can_fetch_liabilities?

      # Once liabilities is billed, errors raise rather than clearing the
      # liabilities already stored; until then it may still be initializing.
      @liabilities_data =
        if liabilities_billed?
          plaid_provider.get_item_liabilities(plaid_item.access_token)
        else
          fetch_product_data("liabilities") do
            plaid_provider.get_item_liabilities(plaid_item.access_token)
          end
        end
    rescue Plaid::ApiError => e
      error_code = plaid_error_code(e)
      raise unless liabilities_unavailable?(error_code)

      log_liabilities_unavailable(error_code)
      @liabilities_data = nil
    end

    # Link records a liabilities consent even when Plaid can't add it: the
    # issuer lacks it, or the user withheld the OAuth permission. Consent alone
    # can't gate the call, so skip the data instead of failing the whole sync.
    # Once liabilities was added to the Item, errors still raise rather than
    # clearing the liabilities already stored.
    def liabilities_unavailable?(error_code)
      %w[PRODUCTS_NOT_SUPPORTED ACCESS_NOT_GRANTED NO_LIABILITY_ACCOUNTS].include?(error_code) &&
        !liabilities_billed?
    end

    def liabilities_billed?
      plaid_item.billed_products.map(&:to_s).include?("liabilities")
    end

    # Yields the Plaid API call and rescues transient "product not ready" errors,
    # logging them and returning nil so the product is skipped for this sync cycle.
    # Any other error is re-raised so real failures are not silently swallowed.
    def fetch_product_data(product_name)
      yield
    rescue Plaid::ApiError => e
      error_body = safe_parse_plaid_error(e)
      error_code = error_body["error_code"].to_s

      raise unless TRANSIENT_PRODUCT_ERROR_CODES.include?(error_code)

      DebugLogEntry.capture(
        category: "plaid_sync",
        level: "warn",
        message: "Plaid product '#{product_name}' not ready (#{error_code}) — skipping this sync, will retry",
        source: self.class.name,
        provider_key: "plaid",
        family: plaid_item.family,
        metadata: {
          plaid_item_id: plaid_item.id,
          product: product_name,
          error_code: error_code,
          error_message: error_body["error_message"]
        }
      )

      nil
    end

    def safe_parse_plaid_error(error)
      JSON.parse(error.response_body.to_s)
    rescue JSON::ParserError
      {}
    end

    def log_account_without_balance(account)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "info",
        message: "Skipped Plaid account without a balance",
        source: self.class.name,
        provider_key: "plaid",
        family: plaid_item.family,
        metadata: {
          plaid_item_id: plaid_item.id,
          plaid_account_id: account.account_id,
          type: account.type,
          subtype: account.subtype
        }
      )
    end

    def log_liabilities_unavailable(error_code)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "info",
        message: "Plaid liabilities unavailable for this item",
        source: self.class.name,
        provider_key: "plaid",
        family: plaid_item.family,
        metadata: {
          plaid_item_id: plaid_item.id,
          institution_id: plaid_item.institution_id,
          error_code: error_code
        }
      )
    end

    def plaid_error_code(error)
      body = JSON.parse(error.response_body.to_s)
      body["error_code"] if body.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end
end
