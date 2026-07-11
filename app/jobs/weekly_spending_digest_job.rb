class WeeklySpendingDigestJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Rails.application.config.app_mode.self_hosted?

    end_date = Date.current.prev_day

    Family.find_each do |family|
      begin
        digest = family.weekly_spending_digest(end_date: end_date)
        family.users.each do |user|
          # deliver_now (not _later) on purpose: we are already inside an async
          # worker, and the digest carries Money objects that ActiveJob cannot
          # serialize across a deliver_later GlobalID boundary. Sending here
          # keeps the real object in-process. Do not switch to deliver_later.
          SpendingDigestMailer.with(user: user, digest: digest).weekly.deliver_now
        end
      rescue => e
        Rails.logger.error("WeeklySpendingDigestJob failed for family #{family.id}: #{e.class} #{e.message}")
      end
    end
  end
end
