# Weekday mornings (config/recurring.yml), after the 8:30 social job (#912): if an approved post didn't go out, say so the same
# morning through Autopilot::Alert (one email to hello@ and a Sentry error, again only after 20 h; "back to normal" when it clears).
# Reads only: ids and company slugs in the text, never a post's words. Nothing is sent or changed here.
class SocialQueueWatchJob < ApplicationJob
  queue_as :default

  KEY = "social-queue".freeze
  # Buffer's due time passed and the 5-minute sync still hasn't read the post back.
  QUEUED_LATE = 30.minutes

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
    stopped = CrawlRun.where(source_kind: SocialAgent::STOPPED, started_at: day.in_time_zone(SocialAgent::ZONE).all_day).where("stats ? 'stopped'")
      .filter_map { |run| run.stats["stopped"] if run.stats["stopped"].to_s.start_with?("approved draft") }

    [].tap do |found|
      posts.waiting.where(send_on: ..day).order(:id).each do |post|
        found << "Row #{post.id} (#{post.platform}, #{slug(post)}) was due #{post.send_on} and is still a draft#{": #{stopped.join('; ')}" if stopped.any? && post.send_on == day}."
      end
      posts.where(sent_on: day, status: %w[failed unknown]).order(:id).each do |post|
        found << "Row #{post.id} (#{post.platform}, #{slug(post)}) is #{post.status}#{' (it may have gone out: check the account)' if post.status == 'unknown'}."
      end
      posts.where(status: "queued", posted_at: ..(now - QUEUED_LATE)).order(:id).each do |post|
        found << "Row #{post.id} (#{post.platform}, #{slug(post)}) is still queued #{((now - post.posted_at) / 60).round} minutes after its Buffer due time."
      end
    end
  end

  def self.slug(post) = post.subject.try(:slug).presence || post.subject_type.to_s.underscore
end
