class Family::WeeklySpendingDigest
  CategoryLine = Data.define(:name, :amount, :pct) # amount is a Money

  def initialize(family, end_date:)
    @family = family
    @end_date = end_date
    @period = Period.custom(start_date: end_date - 6, end_date: end_date)
  end

  def posted_total
    Money.new(posted_totals.total, @family.currency)
  end

  # Positive expense categories for the week, largest first.
  def posted_categories
    posted_totals.category_totals
      .reject { |ct| ct.category.subcategory? }
      .select { |ct| ct.total.positive? }
      .sort_by { |ct| -ct.total }
      .map do |ct|
        pct = posted_totals.total.positive? ? ((ct.total.to_d / posted_totals.total) * 100).round : 0
        CategoryLine.new(name: category_name(ct.category), amount: Money.new(ct.total, @family.currency), pct: pct)
      end
  end

  def pending_total
    statement.totals(transactions_scope: @family.transactions.visible.pending, date_range: @period.date_range).expense_money
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
      @statement ||= @family.income_statement(user: nil)
    end

    def posted_totals
      @posted_totals ||= statement.expense_totals(period: @period)
    end

    def category_name(category)
      category.name.presence || "Uncategorized"
    end
end
