module Autopilot
  # A stalled stage of the lead-to-Create pipeline, said out loud (#811): an email through Resend to the team
  # inbox plus a Sentry error. One alert per key: raising it again within REMIND_EVERY does nothing (so a daily
  # health check can call it every run without spamming), and after that it reminds once more while the problem
  # lasts. resolve! says it's back to normal, only if the alert was open.
  #
  #   Autopilot::Alert.raise!("pending-without-role", title: "Pending companies with no role for over 24 h", body: "7 companies: ...")
  #   Autopilot::Alert.resolve!("pending-without-role")
  #
  # Never raises: a mail or Sentry that fails is only logged, so a health check is never stopped by its own alert.
  # Keys are short and stable (they dedupe); bodies are plain text with counts and ids, no secrets.
  module Alert
    REMIND_EVERY = 20.hours

    # :sent, :already (open and recently said), or :failed.
    def self.raise!(key, title:, body:)
      return :already if open?(key)

      store.write(cache_key(key), Time.current.to_i, expires_in: REMIND_EVERY)
      Rails.logger.warn("[autopilot] #{key}: #{title}")
      report(key, title:, body:)
      AutopilotMailer.notify(key:, title:, body:, state: :raised)
      :sent
    rescue StandardError => error
      Rails.logger.error("[autopilot] couldn't raise #{key}: #{error.class}: #{error.message}")
      :failed
    end

    # :resolved, or nil when it wasn't open.
    def self.resolve!(key, note: "Back to normal.")
      return unless open?(key)

      store.delete(cache_key(key))
      Rails.logger.info("[autopilot] #{key}: resolved")
      AutopilotMailer.notify(key:, title: "Resolved: #{key}", body: note, state: :resolved)
      :resolved
    rescue StandardError => error
      Rails.logger.error("[autopilot] couldn't resolve #{key}: #{error.class}: #{error.message}")
      nil
    end

    def self.open?(key) = store.exist?(cache_key(key))

    # Rails.cache (the database-backed solid_cache, entries live a day at most: so a reminder a day while it lasts);
    # tests set their own.
    class << self
      attr_writer :store

      def store = @store || Rails.cache
    end
    def self.cache_key(key) = "autopilot/alert/#{key}"

    def self.report(key, title:, body:)
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
