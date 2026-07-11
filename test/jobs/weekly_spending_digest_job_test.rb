require "test_helper"

class WeeklySpendingDigestJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  test "delivers a weekly digest email for each family user in self-hosted mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    expected = User.where.not(family_id: nil).count

    assert_emails expected do
      WeeklySpendingDigestJob.perform_now
    end
  end

  test "does nothing in managed mode" do
    Rails.application.config.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("managed"))
    assert_no_emails do
      WeeklySpendingDigestJob.perform_now
    end
  end
end
