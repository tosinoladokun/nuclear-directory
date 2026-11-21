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
end
