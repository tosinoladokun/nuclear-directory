module Autopilot
  # A stalled stage of the lead-to-Create pipeline, said out loud (#811): an email through Resend to the team
  # inbox plus a Sentry error. One alert per key, kept in the database until it's resolved: raising it again before
  # REMIND_EVERY does nothing (so a daily health check can call it every run without spamming), then it reminds
  # once more for as long as the problem lasts; resolve! says it's back to normal, however many days later, only
  # if it was open.
  #
  #   Autopilot::Alert.raise!("pending-without-role", title: "Pending companies with no role for over 24 h", body: "7 companies: ...")
  #   Autopilot::Alert.resolve!("pending-without-role")
  #
  # Each channel is its own: a Sentry outage never stops the email, and a failed email is tried again on the next
  # call (its time is only written once it was queued), without re-sending a Sentry report that already went out.
  # Never raises: a failure is only logged, so a health check is never stopped by its own alert. Keys are short and
  # stable (they dedupe); bodies are plain text with counts and ids, no secrets.
  module Alert
    REMIND_EVERY = 20.hours

    class << self
      # Tests replace it; it takes (key, title, body).
      attr_writer :reporter

      def reporter = @reporter || method(:report)
    end

    # :sent (something went out), :already (open, and said recently), or :failed (nothing could be said).
    def self.raise!(key, title:, body:)
      now = Time.current
      alert = AutopilotAlert.find_or_initialize_by(key: key.to_s)
      alert.assign_attributes(title:, opened_at: now, last_emailed_at: nil, last_reported_at: nil, resolved_at: nil) unless alert.persisted? && alert.open?
      alert.title = title
      alert.save!
      Rails.logger.warn("[autopilot] #{key}: #{title}")

      sent = [ channel(alert, :last_reported_at, now) { reporter.call(key, title, body) },
               channel(alert, :last_emailed_at, now) { AutopilotMailer.notify(key:, title:, body:, state: :raised) } ]
      sent.any? ? :sent : (sent.all?(&:nil?) ? :already : :failed)
    rescue StandardError => error
      Rails.logger.error("[autopilot] couldn't raise #{key}: #{error.class}: #{error.message}")
      :failed
    end

    # :resolved, or nil when it wasn't open (or the email couldn't be queued: it stays open and is tried again).
    def self.resolve!(key, note: "Back to normal.")
      alert = AutopilotAlert.open.find_by(key: key.to_s) or return

      AutopilotMailer.notify(key:, title: "Resolved: #{key}", body: note, state: :resolved)
      alert.update!(resolved_at: Time.current)
      Rails.logger.info("[autopilot] #{key}: resolved")
      :resolved
    rescue StandardError => error
      Rails.logger.error("[autopilot] couldn't resolve #{key}: #{error.class}: #{error.message}")
      nil
    end

    def self.open?(key) = AutopilotAlert.open.exists?(key: key.to_s)

    # Runs the block if the channel is due (never done, or REMIND_EVERY ago); records its time only when it worked.
    # true: sent; nil: not due; false: failed.
    def self.channel(alert, column, now)
      last = alert[column]
      return if last && last > now - REMIND_EVERY

      yield
      alert.update!(column => now)
      true
    rescue StandardError => error
      Rails.logger.error("[autopilot] #{alert.key}: #{column.to_s.delete_prefix('last_').delete_suffix('_at')} failed: #{error.class}: #{error.message}")
      false
    end
    private_class_method :channel

    def self.report(key, title, body)
      return unless defined?(Sentry) && Sentry.initialized?

      Sentry.with_scope do |scope|
        scope.set_fingerprint([ "autopilot", key.to_s ])
        scope.set_context("autopilot", { key:, body: body.to_s.truncate(2_000) })
        Sentry.capture_message("Autopilot: #{title}", level: :error)
      end
    end
    private_class_method :report
  end
end
