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
    # Upstream replaced langfuse-ruby with OpenTelemetry as the transport for
    # the SAME Langfuse integration (2026-10-26). These seven gems are pulled in
    # by lib/langfuse_tracing.rb and are constructed ONLY inside the
    # LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY guard in langfuse.rb -- there is
    # no global OpenTelemetry::SDK.configure and no auto-instrumentation, which
    # the test below enforces. Reviewed and allowlisted deliberately.
    "langfuse-ruby"                      => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] },
    "opentelemetry-api"                  => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] },
    "opentelemetry-common"               => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] },
    "opentelemetry-exporter-otlp"        => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] },
    "opentelemetry-exporter-otlp-common" => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] },
    "opentelemetry-registry"             => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] },
    "opentelemetry-sdk"                  => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] },
    "opentelemetry-semantic_conventions" => { initializer: "langfuse.rb", env: %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] }
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

      # Deliberately a mention check, not a structural one: these initializers
      # gate in different shapes (sentry/langfuse branch on ENV directly;
      # posthog assigns ENV to a config object and branches on that), so a
      # same-line regex produces false failures. The risk this actually catches
      # is upstream RENAMING or REMOVING the variable our deploy config sets --
      # which would silently turn our opt-out into a no-op. Structural gating is
      # covered by the unconditional-construction test and the Langfuse test.
      assert config[:env].any? { |var| source.include?(var) },
        "#{config[:initializer]} no longer references any of #{config[:env].inspect}. Our " \
        "production relies on those being unset/false to keep #{gem} inert; if upstream " \
        "renamed or removed the gate, this may now transmit. Re-check the initializer and " \
        "update .env AND the compose x-rails-env anchor before shipping."
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

  # OpenTelemetry is only safe here because it is never configured globally.
  # A global `OpenTelemetry::SDK.configure`, an auto-instrumentation gem, or a
  # tracer_provider assignment would read OTEL_EXPORTER_OTLP_ENDPOINT and could
  # start exporting spans with no Langfuse key set at all -- bypassing the gate
  # every other check in this file relies on.
  test "OpenTelemetry is never configured globally" do
    offenders = Dir[Rails.root.join("{app,lib,config}/**/*.rb")].select do |file|
      File.read(file).match?(/OpenTelemetry::SDK\.configure|OpenTelemetry\.tracer_provider\s*=|use_all\b/)
    end

    assert_empty offenders.map { |f| f.sub("#{Rails.root}/", "") },
      "OpenTelemetry is configured globally. It must only be instantiated inside the " \
      "LANGFUSE_* guard in config/initializers/langfuse.rb. A global setup reads " \
      "OTEL_EXPORTER_OTLP_ENDPOINT and can transmit without any Langfuse key being set."
  end

  test "no OpenTelemetry auto-instrumentation gem is present" do
    locked = File.read(Rails.root.join("Gemfile.lock")).scan(/^    (opentelemetry-instrumentation[a-z0-9_-]*) \(/).flatten
    assert_empty locked,
      "An OpenTelemetry auto-instrumentation gem appeared. Those hook HTTP/DB calls " \
      "and export automatically -- confirm what it transmits before allowlisting."
  end

  # Langfuse now pulls in the OpenTelemetry exporter, so its gate matters more
  # than before: the tracer must be CONSTRUCTED inside the key check, not merely
  # mention the keys. Deleting the `if` while leaving ENV.fetch in the
  # constructor passed the mention check above, so this asserts the structure.
  test "the Langfuse tracer is constructed only inside its key gate" do
    source = Rails.root.join("config/initializers/langfuse.rb").read
    gate = source[/^if .*LANGFUSE_PUBLIC_KEY.*LANGFUSE_SECRET_KEY.*$/]

    assert gate,
      "config/initializers/langfuse.rb no longer opens with an `if` on both LANGFUSE_PUBLIC_KEY " \
      "and LANGFUSE_SECRET_KEY. Without that gate the OpenTelemetry exporter can be built and " \
      "start a background export thread with no key configured."

    # Upstream has changed this constructor before (Langfuse.configure ->
    # LangfuseTracing.new when it moved onto OpenTelemetry), so accept either
    # and fail loudly if it becomes something new we have not reviewed.
    ctor = [ "LangfuseTracing.new", "Langfuse.configure" ].find { |c| source.include?(c) }
    assert ctor,
      "langfuse.rb no longer uses a known constructor (LangfuseTracing.new / Langfuse.configure). " \
      "Upstream changed how tracing is set up -- re-read the file and confirm it still cannot " \
      "transmit without LANGFUSE_* set, then update this guard."

    assert_operator source.index(ctor), :>, source.index(gate),
      "#{ctor} runs before/outside the LANGFUSE_* gate in langfuse.rb."
  end
end
