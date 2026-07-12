class WeeklySpendingDigestJob < ApplicationJob
  queue_as :scheduled

  TZ = "America/New_York"

  # Runs hourly. Self-heals: sends once per week, the first run at/after
  # Monday 7 AM ET. If the machine was asleep at 7 AM, the next hourly run
  # after power-on sends it. A per-family marker prevents duplicate sends.
  def perform
    return unless Rails.application.config.app_mode.self_hosted?

    target = target_send_time            # most recent Monday 07:00 ET
    end_date = target.to_date.prev_day   # Sunday that ends the completed week

    Family.find_each do |family|
      begin
        # with_lock serializes concurrent runs (e.g. the hourly cron overlapping
        # a manual trigger, or a run exceeding the hour): it reloads the row
        # FOR UPDATE, so a second runner waits, then re-reads the now-set marker
        # and skips — preventing a duplicate send. Marker is written only after
        # a successful send (send-then-mark), so a crash mid-send leaves it unset
        # and the next hourly run retries rather than silently dropping the week.
        family.with_lock do
          next if already_sent?(family, target)
          digest = family.weekly_spending_digest(end_date: end_date)
          family.users.each do |user|
            # deliver_now (not _later): already inside an async worker, and the
            # digest carries Money objects ActiveJob can't serialize across a
            # deliver_later GlobalID boundary. Do not switch to deliver_later.
            SpendingDigestMailer.with(user: user, digest: digest).weekly.deliver_now
          end
          family.update_column(:last_weekly_digest_sent_on, target.to_date)
        end
      rescue => e
        Rails.logger.error("WeeklySpendingDigestJob failed for family #{family.id}: #{e.class} #{e.message}")
      end
    end
  end

  private
    def target_send_time
      now = Time.find_zone!(TZ).now
      monday_7 = now.beginning_of_week(:monday).change(hour: 7, min: 0, sec: 0)
      now >= monday_7 ? monday_7 : monday_7 - 1.week
    end

    def already_sent?(family, target)
      d = family.last_weekly_digest_sent_on
      d.present? && d >= target.to_date
    end
end
