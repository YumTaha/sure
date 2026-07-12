require "test_helper"

class WeeklySpendingDigestJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    Family.update_all(last_weekly_digest_sent_on: nil)
  end

  test "sends past target when unsent (Monday 8 AM ET)" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    expected = User.where.not(family_id: nil).count

    travel_to Time.utc(2026, 7, 13, 12, 0, 0) do # Mon 8:00 AM ET
      assert_emails expected do
        WeeklySpendingDigestJob.perform_now
      end
    end

    Family.find_each do |family|
      next if family.users.empty?
      assert_equal Date.new(2026, 7, 13), family.last_weekly_digest_sent_on
    end
  end

  test "catch-up later same day does not resend (marker prevents duplicate)" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    expected = User.where.not(family_id: nil).count

    travel_to Time.utc(2026, 7, 13, 12, 0, 0) do # Mon 8:00 AM ET
      assert_emails expected do
        WeeklySpendingDigestJob.perform_now
      end

      ActionMailer::Base.deliveries.clear

      assert_no_emails do
        WeeklySpendingDigestJob.perform_now
      end
    end
  end

  test "does nothing in managed mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("managed"))

    travel_to Time.utc(2026, 7, 13, 12, 0, 0) do
      assert_no_emails do
        WeeklySpendingDigestJob.perform_now
      end
    end
  end

  test "before this week's Monday 7 AM ET, catches up on last week's unsent digest" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    expected = User.where.not(family_id: nil).count

    # 2026-07-13 06:00 UTC is 2:00 AM ET Monday, i.e. before this week's 7 AM
    # ET target. The most recent Monday 7 AM ET target is therefore last
    # week's (Jul 6).
    travel_to Time.utc(2026, 7, 13, 6, 0, 0) do
      assert_emails expected do
        WeeklySpendingDigestJob.perform_now
      end
    end

    Family.find_each do |family|
      next if family.users.empty?
      assert_equal Date.new(2026, 7, 6), family.last_weekly_digest_sent_on
    end
  end
end
