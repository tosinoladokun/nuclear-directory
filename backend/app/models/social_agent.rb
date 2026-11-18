# The social agent (#769): each weekday morning, one post per platform about fresh directory data, written,
# checked and (when the platform is live) sent. Nothing goes out unless every check passes; every attempt is
# logged as a SocialPost. Each platform has a switch in the admin (off, drafts, live).
module SocialAgent
  ZONE = "America/Los_Angeles"
  SITE = "https://nuclear-directory.org"

  # Senders by platform; X arrives in phase 1b, LinkedIn through a partner scheduler in phase 2.
  def self.senders = @senders ||= {}

  # Sending is on only when SOCIAL_POSTING_ENABLED is "on" (Render dashboard; Infra): otherwise Live drafts too.
  def self.sending_enabled? = ENV["SOCIAL_POSTING_ENABLED"] == "on"
  # What one post costs (X charges $0.20 for a post with a link, which ours always have; Infra) and the most a month may cost. The X balance is the outer cap.
  def self.post_cost = BigDecimal(ENV.fetch("X_POST_COST_USD", "0.20"))
  def self.monthly_cap = BigDecimal(ENV.fetch("SOCIAL_MONTHLY_CAP_USD", "10"))

  # A send whose outcome isn't known (timeout, 5xx, 429): it may have gone out, so it's never sent again.
  class Uncertain < StandardError; end

  # One post for the platform, or nil when it's off, it's a weekend, today's is done, or there's nothing fresh.
  def self.run(platform, now: Time.current, writer: SocialAgent::Writer.new)
    channel = SocialChannel.for(platform)
    return if channel.off? || now.in_time_zone(ZONE).on_weekend?
    return if SocialPost.used.where(platform:, created_at: now.in_time_zone(ZONE).all_day).exists?

    item = SocialAgent::Picker.new(platform:, now:).call or return
    post = SocialPost.new(platform:, subject: item.subject, source_url: item.source_url, source_quote: item.source_quote,
      organization_ids: item.organization_ids, link: link(item, platform))
    post.text = writer.draft(item, platform:)
    problems = SocialAgent::Check.problems(post.text, item, platform:)
    if problems.empty?
      ok, why = writer.voice_ok?(post.text, item)
      problems << "voice check: #{why}" unless ok
    end
    return post.tap { |blocked| blocked.update!(status: "blocked", reason: problems.to_sentence) } if problems.any?
    return post.tap { |draft| draft.update!(status: "drafted") } unless channel.live? && sending_enabled?

    send_post(post, now:)
  end

  # Sends once: under the channel's lock, checks the month's spend, writes the post as sending (one per item and
  # platform, ever), then calls the platform. No retry.
  def self.send_post(post, now: Time.current)
    claimed = SocialChannel.transaction do
      SocialChannel.lock.find_by!(platform: post.platform)
      spent = SocialPost.where(platform: post.platform, status: SocialPost::SENT, created_at: now.all_month).sum(:cost_usd)
      next post.tap { |over| over.update!(status: "blocked", reason: "this month's cap of $#{monthly_cap.to_s('F')} is reached") } if spent + post_cost > monthly_cap

      post.update!(status: "sending", cost_usd: post_cost)
    end
    return post unless claimed == true

    # Its fact still published at send time (it may have been taken off since the pick).
    unless post.subject.reload.verification_status == "verified"
      return post.tap { |gone| gone.update!(status: "blocked", cost_usd: 0, reason: "its #{post.subject_type == 'NewsItem' ? 'news item' : 'company'} is no longer published") }
    end
    sender = senders[post.platform] or return post.tap { |failed| failed.update!(status: "failed", reason: "#{post.platform} isn't connected") }
    sent = sender.call(post.text, post.link)
    post.tap { |done| done.update!(status: "posted", external_id: sent[:id], permalink: sent[:permalink], posted_at: Time.current) }
  rescue ActiveRecord::RecordNotUnique
    post.tap { |again| again.update!(status: "blocked", reason: "already sent once") }
  rescue Uncertain => error
    post.tap { |unknown| unknown.update!(status: "unknown", reason: "may have gone out (#{error.message}); check the account, never resent".truncate(250)) }
      .tap { pause_after_errors(post.platform) }
  rescue StandardError => error
    post.tap { |failed| failed.update!(status: "failed", cost_usd: 0, reason: "#{error.class}: #{error.message}".truncate(250)) }
      .tap { pause_after_errors(post.platform) }
  end

  # Two sends in a row that errored switch the platform off (Infra); a person looks, then turns it back on.
  PAUSE_AFTER = 2
  def self.pause_after_errors(platform)
    last = SocialPost.where(platform:, status: %w[posted unknown failed]).order(id: :desc).limit(PAUSE_AFTER).pluck(:status)
    return unless last.size == PAUSE_AFTER && last.none?("posted")

    SocialChannel.for(platform).update!(mode: "off", paused_reason: "#{PAUSE_AFTER} sends in a row didn't go through")
  end

  # The record's page, tracked (Social playbook: utm_source x or linkedin-page).
  def self.link(item, platform)
    source = platform == "x" ? "x" : "linkedin-page"
    "#{SITE}#{item.path}?utm_source=#{source}&utm_medium=social&utm_campaign=#{item.kind}"
  end
end
