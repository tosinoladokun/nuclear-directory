# The social agent's posts for Data Quality to read during the shadow days (#769): drafts, posts and the ones a check
# stopped, with why and their source. Read only.
#
#   GET /api/dq/social_posts?since=2026-11-20 => { posts: [{ id, at, platform, status, text, link, source_url, reason, permalink, subject }] }
class Api::Dq::SocialPostsController < ActionController::API
  include Api::DqAgent
  MAX = 200
  # Every check a post passes before it's drafted or sent (#790, #794): a drafted, queued or posted one passed them all.
  CHECKS = [ "numbers in the source", "names in the source", "no link, hashtag or emoji", "no relative time", "platform length",
    "primary source answering 200", "status words in the source", "no person named", "no unquoted superlative",
    "no sensitive topic", "not like a post in 60 days", "not a federal holiday", "voice check" ].freeze

  def index
    since = (Date.iso8601(params[:since].to_s) rescue 7.days.ago.to_date)
    posts = SocialPost.where(created_at: since.beginning_of_day..).order(:created_at).limit(MAX).map do |post|
      { id: post.id, at: post.created_at.iso8601, platform: post.platform, status: post.status, text: post.text, link: post.link,
        source_url: post.source_url, reason: post.reason, permalink: post.permalink, subject: "#{post.subject_type} #{post.subject_id}",
        checks: (post.status.in?(%w[blocked failed]) ? [] : CHECKS) }
    end
    render json: { posts: }
  end
end
