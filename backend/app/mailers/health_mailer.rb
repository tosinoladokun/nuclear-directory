# The pipeline's daily problems by email (#811, PM: no GitHub token; Resend, like the correction alerts), to
# hello@. One email a day at most, listing each stalled stage once. Skipped (and logged) without Resend's key.
class HealthMailer < ApplicationMailer
  FROM = CorrectionMailer::FROM
  TO = "hello@nuclear-directory.org"

  def self.notify(problems)
    return if problems.empty?
    return Rails.logger.info("[health] no email: RESEND_API_KEY not set") if ENV["RESEND_API_KEY"].blank?

    with(problems:).stalled.deliver_later
  end

  def stalled
    @problems = params[:problems]
    subject = @problems.one? ? "Pipeline: #{@problems.first.truncate(80)}" : "Pipeline: #{@problems.size} things stalled"
    mail(from: FROM, to: TO, subject:) { |format| format.text }
  end
end
