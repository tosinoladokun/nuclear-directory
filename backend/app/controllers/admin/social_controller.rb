# The social agent's page (#769): each platform's switch (off, drafts only, live) and every post it drafted,
# checked and sent, with its source.
class Admin::SocialController < Admin::BaseController
  def show
    @channels = SocialChannel::PLATFORMS.map { |platform| SocialChannel.for(platform) }
    @posts = SocialPost.order(created_at: :desc).limit(100)
    @spent = SocialPost.where(status: SocialPost::SENT, created_at: Time.current.all_month).sum(:cost_usd)
  end

  # Draft now (PM, 20 Nov: admin UI over console): today's drafts for the platforms that are on, never sent.
  # The usual rules hold: one a day, weekdays, something fresh.
  def draft_now
    reasons = SocialChannel::PLATFORMS.to_h { |platform| [ platform, SocialAgent.no_draft_reason(platform) ] }
    trying = reasons.select { |_, why| why.nil? }.keys
    skipped = reasons.compact.map { |platform, why| "#{platform == 'x' ? 'X' : 'LinkedIn'}: #{why}" }
    SocialPostJob.perform_later(drafts_only: true) if trying.any?
    notice = trying.any? ? "Drafting now. Reload in a minute to see it in the log." : "No draft."
    notice += " #{trying.any? ? 'Not drafting' : 'Why'}: #{skipped.join('; ')}." if skipped.any?
    redirect_to admin_social_path, notice:
  end

  # A post Tosin made by hand (#877): one "posted" row per platform for the item, so the agent's 14-day cooldown and its one-send
  # index keep it from posting the same item again. The item is a news item by id or by its source URL.
  def by_hand
    item = params[:item].to_s.strip
    news = (NewsItem.find_by(id: item) if item.match?(/\A\d+\z/)) || NewsItem.find_by(url: item)
    platforms = Array(params[:platforms]) & SocialChannel::PLATFORMS
    permalink = params[:permalink].to_s.strip.presence
    if news.nil? || platforms.empty? || (permalink && !permalink.match?(%r{\Ahttps?://\S+\z}))
      redirect_to admin_social_path, alert: "Not recorded: give a news item's id or source URL, at least one platform, and a link that starts with https:// if you add one." and return
    end

    orgs = news.news_mentions.where(subject_type: "Organization").pluck(:subject_id)
    saved, already = platforms.partition do |platform|
      SocialPost.create!(platform:, status: "posted", subject: news, text: "Posted by hand.", source_url: news.url, organization_ids: orgs,
        permalink:, posted_at: Time.current)
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end
    notice = "Recorded for #{saved.map { |p| p == 'x' ? 'X' : 'LinkedIn' }.to_sentence}: the agent won't post it again." if saved.any?
    notice = [ notice, "#{already.map { |p| p == 'x' ? 'X' : 'LinkedIn' }.to_sentence} already had it." ].compact.join(" ") if already.any?
    redirect_to admin_social_path, notice:
  end

  def update
    channel = SocialChannel.for(params[:platform])
    if channel.update(mode: params[:mode], paused_reason: nil)
      SocialAgent.cancel_queued(platform: channel.platform, why: "switched off in the admin") unless channel.live?
      flash[:notice] = { "off" => "Switched off.", "drafts" => "Drafts only: written and checked, never sent.", "live" => "Live." }.fetch(channel.mode)
    else
      flash[:alert] = "Not changed: #{channel.errors.full_messages.to_sentence}."
    end
    redirect_to admin_social_path
  end
end
