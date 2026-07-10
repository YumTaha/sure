class DailySpendingDigestJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Rails.application.config.app_mode.self_hosted?

    date = Date.current.yesterday

    Family.find_each do |family|
      begin
        digest = family.spending_digest(date: date)
        # Convert to a fully serializable hash format
        digest_hash = {
          yesterday_total_amount: digest.yesterday_total.amount.to_i,
          yesterday_total_currency: digest.yesterday_total.currency.to_s,
          mtd_total_amount: digest.mtd_total.amount.to_i,
          mtd_total_currency: digest.mtd_total.currency.to_s,
          currency: digest.currency,
          any_spending: digest.any_spending?,
          categories: digest.categories.map { |c|
            {
              name: c.name,
              amount: c.amount.amount.to_i,
              currency: c.amount.currency.to_s
            }
          }
        }
        family.users.each do |user|
          SpendingDigestMailer.with(user: user, digest: digest_hash).daily.deliver_later
        end
      rescue => e
        Rails.logger.error("DailySpendingDigestJob failed for family #{family.id}: #{e.class} #{e.message}")
      end
    end
  end
end
