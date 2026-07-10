class DailySpendingDigestJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Rails.application.config.app_mode.self_hosted?

    date = Date.current.yesterday

    Family.find_each do |family|
      begin
        digest = family.spending_digest(date: date)
        family.users.each do |user|
          SpendingDigestMailer.with(user: user, digest: digest).daily.deliver_now
        end
      rescue => e
        Rails.logger.error("DailySpendingDigestJob failed for family #{family.id}: #{e.class} #{e.message}")
      end
    end
  end
end
