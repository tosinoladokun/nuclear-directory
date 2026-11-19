# The social agent's posts for Data Quality to read during the shadow days (#769): drafts, posts and the ones a check
# stopped, with why and their source. Read only.
#
#   GET /api/dq/social_posts?since=2026-11-20 => { posts: [{ id, at, platform, status, text, link, source_url, reason, permalink, subject }] }
class Api::Dq::SocialPostsController < ActionController::API
  include Api::DqAgent
  MAX = 200
  # Not a list that could go stale (Infra): a post that wasn't stopped passed every check in SocialAgent::Check,
  # SocialAgent::Rules and the voice check, as they stood when it ran.
  PASSED = "passed every check (SocialAgent::Check, SocialAgent::Rules, voice)".freeze

  def index
    since = (Date.iso8601(params[:since].to_s) rescue 7.days.ago.to_date)
    posts = SocialPost.where(created_at: since.beginning_of_day..).order(:created_at).limit(MAX).map do |post|
      { id: post.id, at: post.created_at.iso8601, platform: post.platform, status: post.status, text: post.text, link: post.link,
        source_url: post.source_url, reason: post.reason, permalink: post.permalink, subject: "#{post.subject_type} #{post.subject_id}",
        checks: (post.status.in?(%w[blocked failed]) ? nil : PASSED) }
    end
    render json: { posts: }
  end
end
