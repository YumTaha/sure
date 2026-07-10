class Family::SpendingDigest
  CategoryLine = Data.define(:name, :amount) # amount is a Money

  def initialize(family, date:)
    @family = family
    @date = date
  end

  def yesterday_total
    Money.new(day_totals.total, @family.currency)
  end

  def mtd_total
    Money.new(mtd_totals.total, @family.currency)
  end

  def currency
    @family.currency
  end

  def any_spending?
    yesterday_total.amount.positive?
  end

  # Positive expense categories for the day, largest first.
  def categories
    day_totals.category_totals
      .reject { |ct| ct.category.subcategory? }
      .select { |ct| ct.total.positive? }
      .sort_by { |ct| -ct.total }
      .map { |ct| CategoryLine.new(name: category_name(ct.category), amount: Money.new(ct.total, @family.currency)) }
  end

  private
    def statement
      @statement ||= @family.income_statement(user: nil)
    end

    def day_totals
      @day_totals ||= statement.expense_totals(period: Period.custom(start_date: @date, end_date: @date))
    end

    def mtd_totals
      @mtd_totals ||= statement.expense_totals(period: Period.custom(start_date: @date.beginning_of_month, end_date: @date))
    end

    def category_name(category)
      category.name.presence || "Uncategorized"
    end
end
