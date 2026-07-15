class Family::WeeklySpendingDigest
  # amount, weekly_budget are Money (weekly_budget nil when un-budgeted)
  # pct: share of the week's posted total (used for the neutral fallback bar)
  # budget_pct: round(amount / weekly_budget * 100), nil when un-budgeted
  # status: :under (<80), :near (80..100), :over (>100), :none (un-budgeted)
  CategoryLine = Data.define(:name, :amount, :pct, :weekly_budget, :budget_pct, :status)

  NEAR_THRESHOLD = 80
  OVER_THRESHOLD = 100

  def initialize(family, end_date:, user:)
    raise ArgumentError, "user is required — the digest must be scoped to a recipient" if user.nil?
    @family = family
    @user = user
    @end_date = end_date
    @period = Period.custom(start_date: end_date - 6, end_date: end_date)
  end

  def posted_total
    Money.new(posted_totals.total, @family.currency)
  end

  # Positive expense categories for the week. Budget-tracked categories
  # (status != :none) lead, followed by un-budgeted ones; each group sorted
  # largest amount first.
  def posted_categories
    posted_totals.category_totals
      .reject { |ct| ct.category.subcategory? }
      .select { |ct| ct.total.positive? }
      .map { |ct| build_category_line(ct) }
      .sort_by { |line| [ line.status == :none ? 1 : 0, -line.amount.amount ] }
  end

  def pending_total
    scope = @family.transactions.visible.pending.in_period(@period)
      .where(entries: { account_id: @user.finance_accounts.select(:id) })
    statement.totals(transactions_scope: scope, date_range: @period.date_range).expense_money
  end

  def estimated_total
    Money.new(posted_total.amount + pending_total.amount, @family.currency)
  end

  def currency
    @family.currency
  end

  def range_label
    "#{@period.start_date.strftime('%b %-d')} – #{@period.end_date.strftime('%b %-d, %Y')}"
  end

  private
    def statement
      @statement ||= @family.income_statement(user: @user)
    end

    def posted_totals
      @posted_totals ||= statement.expense_totals(period: @period)
    end

    def category_name(category)
      category.name.presence || "Uncategorized"
    end

    def build_category_line(ct)
      amount = Money.new(ct.total, @family.currency)
      pct = posted_totals.total.positive? ? ((ct.total.to_d / posted_totals.total) * 100).round : 0

      weekly_budget, budget_pct, status = budget_details_for(ct.category, amount)

      CategoryLine.new(name: category_name(ct.category), amount: amount, pct: pct, weekly_budget: weekly_budget, budget_pct: budget_pct, status: status)
    end

    def budget_details_for(category, amount)
      monthly_limit = monthly_limits[category.id]
      return [ nil, nil, :none ] if monthly_limit.blank? || monthly_limit.zero?

      weekly_target = (monthly_limit * 7 / budget_period_days)
      return [ nil, nil, :none ] unless weekly_target.positive?

      weekly_budget = Money.new(weekly_target, @family.currency)
      budget_pct = (amount.amount / weekly_target * 100).round
      status = if budget_pct < NEAR_THRESHOLD
        :under
      elsif budget_pct <= OVER_THRESHOLD
        :near
      else
        :over
      end

      [ weekly_budget, budget_pct, status ]
    end

    # The Budget whose monthly period covers the window's end date, or nil if
    # the family has no budget configured for that month.
    def current_budget
      return @current_budget if defined?(@current_budget)
      date = @period.end_date
      @current_budget = @family.budgets.where("start_date <= ? AND end_date >= ?", date, date).first
    end

    def budget_period_days
      @budget_period_days ||= (current_budget.end_date - current_budget.start_date).to_i + 1
    end

    # category_id => monthly budgeted_spending (BigDecimal), skipping nil/zero limits.
    # Empty when there's no budget covering the window (all categories => :none).
    def monthly_limits
      @monthly_limits ||= if current_budget
        current_budget.budget_categories.each_with_object({}) do |bc, hash|
          limit = bc[:budgeted_spending]
          next if limit.blank? || limit.zero?
          hash[bc.category_id] = limit
        end
      else
        {}
      end
    end
end
