# Weekday mornings (config/recurring.yml), after the 8:30 social job (#912): if an approved post didn't go out, say so the same
# morning through Autopilot::Alert (one email to hello@ and a Sentry error, again only after 20 h; "back to normal" when it clears).
# Reads only: ids, company slugs and a check's fixed-wording reason in the text, never a post's words or an error message. Nothing is sent or changed here.
class SocialQueueWatchJob < ApplicationJob
  queue_as :default

  KEY = "social-queue".freeze
  # Buffer's due time passed and the 5-minute sync still hasn't read the post back.
  QUEUED_LATE = 30.minutes

  # The 8:30 run's refusals that are safe to forward (fixed wording from SocialAgent.draft_refusal and send_post, no post text, no error
  # message, no provider response). Anything else, an exception or a Buffer reply, is named only as GENERIC (Copilot, #915).
  SAFE_REASONS = [
    /\Aonly a draft that passed every check can be sent \(this one is [a-z]+\)/,
    /\Asending is off on the server \(SOCIAL_POSTING_ENABLED\)/,
    /\A(?:X|LinkedIn) is switched off in Admin > Posts/,
    /\Ait's a (?:weekend|holiday)/,
    /\Athis approved draft is for \d{1,2} [A-Z][a-z]{2}, not today/,
    /\Athis draft is from \d{1,2} [A-Z][a-z]{2}/,
    /\ABuffer's 30-day request allowance is used up/,
    /\Atoday's slot for this platform is already taken/,
    /\Athe same item was posted or tried within the last [\w ]+/,
    /\Aa post about the same company was posted or tried today/,
    /\Aits (?:item|news item|link|company) is no longer published/,
    /\Aits source page no longer answers(?: \(\d{3}\))?/,
    /\Aits checks no longer pass/,
    /\Aits text no longer passes/,
    /\Aits text no longer matches the hash the graders approved/,
    /\AData Quality's approval of its (?:content )?hash is no longer on file/,
    /\Aits card or content hash is missing, so it can't be sent as approved/,
    /\Aits content no longer matches the content hash the graders approved/,
    /\Aits text no longer carries our link exactly once/,
    /\Ait is over X's weighted length now/,
    /\Aits item is no longer one the agent could post/,
    /\Ait is already being sent, or was sent/,
    /\Athis month's \d+ posts are done/,
    /\Athis month's cap of \$[\d.]+ is reached/,
    /\Aalready sent once, or another post for this platform went out today/
  ].freeze
  GENERIC = "see Admin > Posts for why".freeze

  # nil: Autopilot::Alert; tests set a stand-in.
  class_attribute :alerts, default: nil

  def perform(now: Time.current)
    zone = Time.find_zone(SocialAgent::ZONE)
    day = now.in_time_zone(zone).to_date
    return if day.on_weekend? || SocialAgent::Rules.holiday?(day)

    problems = self.class.problems(day:, now:)
    helper = alerts || Autopilot::Alert
    if problems.any?
      helper.raise!(KEY, title: "A social post didn't go out as planned (#{problems.size})", body: "#{problems.join("\n")}\n\nSee Admin > Posts.")
    else
      helper.resolve!(KEY, note: "Today's approved posts went out or are queued at Buffer.")
    end
  end

  def self.problems(day:, now: Time.current)
    live = SocialChannel.where.not(mode: "off").pluck(:platform)
    posts = SocialPost.where(platform: live).includes(:subject)
    stopped = stopped_reasons(day)

    [].tap do |found|
      posts.waiting.where(send_on: ..day).order(:id).each do |post|
        found << "Row #{post.id} (#{post.platform}, #{slug(post)}) was due #{post.send_on} and is still a draft#{": #{stopped[[ post.platform, post.id ]]}" if post.send_on == day && stopped[[ post.platform, post.id ]]}."
      end
      # A graders-approved row due by today, or any row claimed for sending today (sent_on) that send_post then blocked, e.g. at the
      # month's cap (Copilot): neither went out.
      posts.where(status: "blocked").where("(approved_sha256 IS NOT NULL AND send_on <= :day) OR sent_on = :day", day:).order(:id).each do |post|
        found << "Row #{post.id} (#{post.platform}, #{slug(post)}) is an approved post that a check blocked: #{safe(post.reason)}"
      end
      posts.where(sent_on: day, status: %w[failed unknown]).order(:id).each do |post|
        found << "Row #{post.id} (#{post.platform}, #{slug(post)}) is #{post.status}#{' (it may have gone out: check the account)' if post.status == 'unknown'}."
      end
      posts.where(status: "queued", posted_at: ..(now - QUEUED_LATE)).order(:id).each do |post|
        found << "Row #{post.id} (#{post.platform}, #{slug(post)}) is still queued #{((now - post.posted_at) / 60).round} minutes after its Buffer due time."
      end
    end
  end

  # { [platform, row id] => safe reason } from today's stopped 8:30 runs; the latest run for a row wins.
  def self.stopped_reasons(day)
    CrawlRun.where(source_kind: SocialAgent::STOPPED, started_at: day.in_time_zone(SocialAgent::ZONE).all_day).where("stats ? 'stopped'")
      .order(:started_at, :id).each_with_object({}) do |run, found|
        id, why = run.stats["stopped"].to_s.match(/\Aapproved draft (\d+) not sent: (.*)\z/m)&.captures
        found[[ run.stats["platform"], id.to_i ]] = safe(why) if id
      end
  end

  def self.safe(reason) = SAFE_REASONS.lazy.filter_map { |pattern| reason.to_s[pattern] }.first || GENERIC

  def self.slug(post) = post.subject.try(:slug).presence || post.subject_type.to_s.underscore
end
