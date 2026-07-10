class DailySpendingDigestJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Rails.application.config.app_mode.self_hosted?

    date = Date.current.yesterday

    Family.find_each do |family|
      begin
        digest = family.spending_digest(date: date)
        family.users.each do |user|
          # deliver_now (not _later) on purpose: we are already inside an async
          # worker, and the digest carries Money objects that ActiveJob cannot
          # serialize across a deliver_later GlobalID boundary. Sending here
          # keeps the real object in-process. Do not switch to deliver_later.
          SpendingDigestMailer.with(user: user, digest: digest).daily.deliver_now
        end
      rescue => e
        Rails.logger.error("DailySpendingDigestJob failed for family #{family.id}: #{e.class} #{e.message}")
      end
    end
  end
end
