# The social agent's page (#769): each platform's switch (off, drafts only, live) and every post it drafted,
# checked and sent, with its source.
class Admin::SocialController < Admin::BaseController
  def show
    @channels = SocialChannel::PLATFORMS.map { |platform| SocialChannel.for(platform) }
    @posts = SocialPost.order(created_at: :desc).limit(100)
    @queue = SocialPost.waiting.includes(:subject).order(:send_on, :platform)
    @spent = SocialPost.where(status: SocialPost::SENT).in_month(Time.current).sum(:cost_usd)
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

  # Send this draft (#879): the exact draft Tosin graded, only after every guard (SocialAgent.send_draft).
  def send_draft
    post = SocialPost.find(params[:id])
    sent, why = SocialAgent.send_draft(post)
    where = post.platform == "x" ? "X" : "LinkedIn"
    if why
      redirect_to admin_social_path, alert: "Not sent to #{where}: #{why}."
    else
      redirect_to admin_social_path, notice: sent.status == "posted" ? "Sent to #{where}." : "Handed to Buffer for #{where}: it goes out at #{sent.posted_at&.in_time_zone(SocialAgent::ZONE)&.strftime('%-d %b %H:%M')}."
    end
  end

  # Takes a row out of the approved queue (#897): it never goes out; the graders can load a new one.
  def cancel_queued
    post = SocialPost.find(params[:id])
    if post.status == "drafted" && post.graded?
      post.update!(status: "cancelled", reason: "taken out of the approved queue in Admin > Posts", send_on: nil)
      redirect_to admin_social_path, notice: "Taken out of the queue: it won't go out."
    else
      redirect_to admin_social_path, alert: "Only a post waiting in the approved queue can be taken out."
    end
  end

  # A post Tosin made by hand (#877): one "posted" row per platform for the item, so the agent's 14-day cooldown and its one-send
  # index keep it from posting the same item again. The item is a news item by id, by its admin page address
  # (/admin/facts/NewsItem/69, relative or absolute) or by its source URL. The rows say they were posted by hand: no check ran on them.
  def by_hand
    item = params[:item].to_s.strip
    id = item[/\A\d+\z/] || item[%r{\Ahttps?://[^/]+/admin/facts/NewsItem/(\d+)\b}, 1] || item[%r{\A/admin/facts/NewsItem/(\d+)\b}, 1]
    news = (NewsItem.find_by(id:) if id) || NewsItem.find_by(url: item)
    platforms = Array(params[:platforms]) & SocialChannel::PLATFORMS
    permalink = params[:permalink].to_s.strip.presence
    if news.nil? || platforms.empty? || (permalink && !web_address?(permalink))
      redirect_to admin_social_path, alert: "Not recorded: give a news item's id, its address in Admin or its source URL, at least one platform, and a link that starts with https:// and has a site name if you add one." and return
    end

    name = ->(platform) { platform == "x" ? "X" : "LinkedIn" }
    orgs = news.news_mentions.where(subject_type: "Organization").pluck(:subject_id)
    # Under the same channel locks the agent's send takes, all platforms or none: a post the agent already has for this item is a
    # harmless repeat when it is finished, and a warning when it is still going out (queued in Buffer, sending, or unsure), so a
    # duplicate can't slip out between the check and the record.
    pending = {}
    saved = []
    already = []
    SocialChannel.transaction do
      platforms.sort.each { |platform| SocialChannel.for(platform).lock! }
      platforms.each do |platform|
        existing = SocialPost.where(platform:, subject: news, status: SocialPost::SENT).order(:id).last
        if existing&.status.in?(%w[queued sending unknown]) then pending[platform] = existing
        elsif existing then already << platform
        end
      end
      raise ActiveRecord::Rollback if pending.any?

      (platforms - already).each do |platform|
        SocialPost.create!(platform:, status: "posted", subject: news, text: "Posted by hand.", reason: SocialPost::BY_HAND, source_url: news.url,
          organization_ids: orgs, permalink:, posted_at: Time.current)
        saved << platform
      end
    end
    if pending.any?
      redirect_to admin_social_path, alert: "Not recorded: #{pending.map { |platform, post| "#{name.(platform)} has an automated post #{post.status == 'queued' ? 'queued in Buffer' : "marked #{post.status}"}" }.to_sentence}. " \
        "Take it back first: switch #{pending.keys.map(&name).to_sentence} off under Switches or remove it in Buffer for a queued one; for one marked unknown, check the account and say what happened on its row in the log (it never went out / it did). Then record yours." and return
    end
    notice = "Recorded for #{saved.map(&name).to_sentence}: the agent won't post it again." if saved.any?
    notice = [ notice, "#{already.map(&name).to_sentence} already had it." ].compact.join(" ") if already.any?
    redirect_to admin_social_path, notice:
  end

  # An automated post marked "unknown" (the send may have gone out): after checking the account, Tosin says which. "Never went out" takes
  # it back, so the item can be sent or recorded again; "It did go out" keeps it as posted. Nothing else unblocks it (#877).
  def reconcile
    outcome = params[:outcome].to_s
    return redirect_to(admin_social_path, alert: "Say whether it went out or never went out.") unless %w[sent never].include?(outcome)

    permalink = params[:permalink].to_s.strip.presence
    return redirect_to(admin_social_path, alert: "That link isn't a web address.") if permalink && !web_address?(permalink)

    # Still unknown under the row's lock: a late Buffer answer may have settled it first.
    result = SocialPost.transaction do
      post = SocialPost.lock.find(params[:id])
      next :settled unless post.status == "unknown"

      if outcome == "sent"
        post.update!(status: "posted", reason: "confirmed by hand: it went out", permalink: permalink || post.permalink, posted_at: post.posted_at || Time.current)
      else
        post.update!(status: "cancelled", cost_usd: 0, reason: "confirmed by hand: it never went out")
      end
      outcome.to_sym
    end
    case result
    when :settled then redirect_to admin_social_path, alert: "Only a post marked unknown needs this."
    when :sent then redirect_to admin_social_path, notice: "Kept as posted: the agent won't post this item again."
    else redirect_to admin_social_path, notice: "Taken back: it never went out, so the item can be recorded or sent again."
    end
  end

  def update
    channel = SocialChannel.for(params[:platform])
    if channel.update(mode: params[:mode], paused_reason: nil)
      SocialAgent.cancel_queued(platform: channel.platform, why: "switched off in the admin", keep_approved: !channel.off?) unless channel.live?
      flash[:notice] = { "off" => "Switched off.", "drafts" => "Drafts only: written and checked, never sent.", "live" => "Live." }.fetch(channel.mode)
    else
      flash[:alert] = "Not changed: #{channel.errors.full_messages.to_sentence}."
    end
    redirect_to admin_social_path
  end

  private
    # A real web address: http or https with a host (never "https://?" or "https:///x").
    def web_address?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTP) && uri.host.present? && !value.match?(/\s/)
    rescue URI::InvalidURIError
      false
    end
end
