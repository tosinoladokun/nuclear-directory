# The social agent's page (#769): each platform's switch (off, drafts only, live) and every post it drafted,
# checked and sent, with its source.
class Admin::SocialController < Admin::BaseController
  def show
    @channels = SocialChannel::PLATFORMS.map { |platform| SocialChannel.for(platform) }
    @posts = SocialPost.order(created_at: :desc).limit(100)
  end

  def update
    channel = SocialChannel.for(params[:platform])
    if channel.update(mode: params[:mode])
      flash[:notice] = { "off" => "Switched off.", "drafts" => "Drafts only: written and checked, never sent.", "live" => "Live." }.fetch(channel.mode)
    else
      flash[:alert] = "Not changed: #{channel.errors.full_messages.to_sentence}."
    end
    redirect_to admin_social_path
  end
end
