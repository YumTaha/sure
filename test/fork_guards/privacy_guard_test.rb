require "test_helper"

# PRIVACY GUARD -- this fork sends telemetry to nobody.
#
# This instance is a self-hosted personal-finance app on a private tailnet. The
# owner's standing rule (2026-10-09) is that no analytics, tracing or usage data
# leaves the box, ever. These tests are the tripwire that keeps an upstream sync
# from quietly changing that: they fail the build when a new egress path appears
# or an existing one stops being gated the way our deployment assumes.
#
# They deliberately assert on SOURCE and CONFIG rather than runtime, because in
# the test environment every client below is inert anyway -- which is exactly
# why a runtime-only check would prove nothing.
class PrivacyGuardTest < ActiveSupport::TestCase
  # Every known outbound telemetry/observability integration, and the ENV knob
  # that must gate it. Adding an entry here is a deliberate, reviewed act.
  #
  # posthog is the dangerous one: upstream defaults POSTHOG_FEEDBACK_ENABLED to
  # "true" in production, so production MUST set it false (we do, in both
  # ~/docker-apps/sure/.env and the x-rails-env anchor of compose.yml).
  KNOWN_TELEMETRY = {
    "posthog-ruby"  => { initializer: "posthog.rb",  env: %w[POSTHOG_KEY POSTHOG_FEEDBACK_ENABLED] },
    "sentry-ruby"   => { initializer: "sentry.rb",   env: %w[SENTRY_DSN] },
    "sentry-rails"  => { initializer: "sentry.rb",   env: %w[SENTRY_DSN] },
    "sentry-sidekiq" => { initializer: "sentry.rb",  env: %w[SENTRY_DSN] },
    "skylight"      => { initializer: nil,           env: %w[SKYLIGHT_AUTHENTICATION] },
    "langfuse-ruby" => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] }
  }.freeze

  # Substrings that identify an analytics/telemetry SDK in Gemfile.lock.
  TELEMETRY_GEM_PATTERNS = %w[
    posthog sentry skylight newrelic ddtrace datadog honeybadger bugsnag
    rollbar scout_apm appsignal mixpanel segment amplitude analytics-ruby
    langfuse opentelemetry elastic-apm instana airbrake
  ].freeze

  test "no telemetry gem appears that this fork has not reviewed" do
    locked = File.read(Rails.root.join("Gemfile.lock"))
      .scan(/^    ([a-z0-9_-]+) \(/).flatten.uniq

    found = locked.select { |gem| TELEMETRY_GEM_PATTERNS.any? { |p| gem.include?(p) } }
    unreviewed = found - KNOWN_TELEMETRY.keys

    assert_empty unreviewed,
      "New telemetry/analytics gem(s) #{unreviewed.inspect} appeared. STOP: confirm what they " \
      "transmit and how they are gated, disable them in production (.env AND the compose " \
      "x-rails-env anchor), then add them to KNOWN_TELEMETRY. Privacy rule: nothing leaves the box."
  end

  test "every known telemetry integration is still ENV-gated, never on by default in code" do
    KNOWN_TELEMETRY.each do |gem, config|
      next unless config[:initializer]

      path = Rails.root.join("config/initializers", config[:initializer])
      assert path.exist?, "#{config[:initializer]} vanished -- re-verify how #{gem} is now configured and gated."

      source = path.read
      assert config[:env].any? { |var| source.include?(var) },
        "#{config[:initializer]} no longer references any of #{config[:env].inspect}. The gate our " \
        "production config relies on may have been renamed or removed, which would silently " \
        "re-enable #{gem}. Re-check the initializer and update the deploy env accordingly."
    end
  end

  # The specific trap: our production disables PostHog by setting
  # POSTHOG_FEEDBACK_ENABLED=false. If upstream renames that variable, our
  # setting becomes a dead no-op and telemetry turns itself back on, silently.
  test "the PostHog opt-out knob our production relies on still exists by name" do
    source = Rails.root.join("config/initializers/posthog.rb").read

    assert_includes source, "POSTHOG_FEEDBACK_ENABLED",
      "POSTHOG_FEEDBACK_ENABLED is gone from posthog.rb. Production sets this to false to stop " \
      "the daily web_ui_served_daily event (which includes the requester IP with geo-IP enabled). " \
      "If it was renamed, update .env AND the compose x-rails-env anchor to the new name BEFORE " \
      "deploying, or analytics resumes without anyone noticing."
  end

  test "no telemetry client is constructed unconditionally" do
    Dir[Rails.root.join("config/initializers/*.rb")].each do |file|
      # Strip comments first: a commented-out example (e.g. the posthog.com host
      # in the default content_security_policy.rb) is not executable code.
      source = File.read(file).lines.reject { |line| line.strip.start_with?("#") }.join
      next unless TELEMETRY_GEM_PATTERNS.any? { |p| source.downcase.include?(p) }

      assert_match(/\bif\b|\bunless\b|\.present\?|ENV\[|ENV\.fetch/, source,
        "#{File.basename(file)} references a telemetry SDK but contains no conditional or ENV " \
        "lookup -- it may initialize a client unconditionally. Verify it cannot transmit anything.")
    end
  end
end
