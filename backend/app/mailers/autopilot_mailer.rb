# The autopilot's alerts (#811), in plain text, through Resend, to the team inbox. Sent later (Solid Queue) and
# skipped, with a log line, when Resend's key is missing. The address is public (the site's contact address);
# AUTOPILOT_NOTIFY_TO overrides it.
#
#   AutopilotMailer.notify(key:, title:, body:, state: :raised)
class AutopilotMailer < ApplicationMailer
  FROM = CorrectionMailer::FROM
  TO = "hello@nuclear-directory.org".freeze

  def self.notify(key:, title:, body:, state:, deliver_now: false)
    return Rails.logger.info("[autopilot] no email for #{key}: RESEND_API_KEY not set") if ENV["RESEND_API_KEY"].blank?

    mail = with(key:, title:, body:, state:).alert
    deliver_now ? mail.deliver_now : mail.deliver_later
  end

  def alert
    @key, @title, @body, @state = params.values_at(:key, :title, :body, :state)
    mail(from: FROM, to: ENV["AUTOPILOT_NOTIFY_TO"].presence || TO,
      subject: "[autopilot] #{@title.to_s.truncate(120)}") { |format| format.text }
  end
end
