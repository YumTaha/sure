require "test_helper"

class DailySpendingDigestJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  test "delivers a daily digest email for each family user in self-hosted mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    expected = User.where.not(family_id: nil).count

    assert_emails expected do
      DailySpendingDigestJob.perform_now
    end
  end

  test "does nothing in managed mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("managed"))
    assert_no_emails do
      DailySpendingDigestJob.perform_now
    end
  end
end
