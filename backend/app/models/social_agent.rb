# The social agent (#769): each weekday morning, one post per platform about fresh directory data, written,
# checked and (when the platform is live) sent. Nothing goes out unless every check passes; every attempt is
# logged as a SocialPost. Each platform has a switch in the admin (off, drafts, live).
module SocialAgent
  ZONE = "America/Los_Angeles"
  SITE = "https://nuclear-directory.org"

  # Senders by platform; X arrives in phase 1b, LinkedIn through a partner scheduler in phase 2.
  def self.senders = @senders ||= {}

  # One post for the platform, or nil when it's off, it's a weekend, today's is done, or there's nothing fresh.
  def self.run(platform, now: Time.current, writer: SocialAgent::Writer.new)
    channel = SocialChannel.for(platform)
    return if channel.off? || now.in_time_zone(ZONE).on_weekend?
    return if SocialPost.where(platform:, status: %w[posted drafted], created_at: now.in_time_zone(ZONE).all_day).exists?

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
    return post.tap { |draft| draft.update!(status: "drafted") } unless channel.live?

    send_post(post)
  end

  def self.send_post(post)
    sender = senders[post.platform] or return post.tap { |failed| failed.update!(status: "failed", reason: "#{post.platform} isn't connected") }
    sent = sender.call(post.text, post.link)
    post.tap { |done| done.update!(status: "posted", external_id: sent[:id], permalink: sent[:permalink], posted_at: Time.current) }
  rescue StandardError => error
    post.tap { |failed| failed.update!(status: "failed", reason: "#{error.class}: #{error.message}".truncate(250)) }
  end

  # The record's page, tracked (Social playbook: utm_source x or linkedin-page).
  def self.link(item, platform)
    source = platform == "x" ? "x" : "linkedin-page"
    "#{SITE}#{item.path}?utm_source=#{source}&utm_medium=social&utm_campaign=#{item.kind}"
  end
end
