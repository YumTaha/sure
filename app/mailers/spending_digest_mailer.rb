class SpendingDigestMailer < ApplicationMailer
  def daily
    @user = params[:user]
    @digest = normalize_digest(params[:digest])
    mail(
      to: @user.email,
      subject: t("spending_digest_mailer.daily.subject", amount: @digest.yesterday_total.format)
    )
  end

  private

  def normalize_digest(digest)
    # If it's already a proper digest object (from tests or direct calls), return as is
    return digest if digest.respond_to?(:yesterday_total) && digest.yesterday_total.is_a?(Money)

    # If it's a hash from ActiveJob deserialization, convert back to an object-like structure
    if digest.is_a?(Hash)
      OpenStruct.new(
        yesterday_total: Money.new(digest["yesterday_total_amount"], digest["yesterday_total_currency"]),
        mtd_total: Money.new(digest["mtd_total_amount"], digest["mtd_total_currency"]),
        currency: digest["currency"],
        any_spending?: digest["any_spending"],
        categories: digest["categories"].map { |cat|
          Family::SpendingDigest::CategoryLine.new(
            name: cat["name"],
            amount: Money.new(cat["amount"], cat["currency"])
          )
        }
      )
    else
      digest
    end
  end
end
