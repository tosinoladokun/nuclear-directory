# How a spotlight opens (#884, Tosin 21 Nov): patterns from config/social_spotlight_openers.yml with {name}. Each post is given a pattern not used in the
# last RECENT posts on its platform; a check blocks an opener that repeats one of them.
module SocialAgent::Openers
  RECENT = 5
  module_function

  def patterns = @patterns ||= Array(YAML.safe_load_file(Rails.root.join("config/social_spotlight_openers.yml"))).map(&:to_s).compact_blank
  def patterns=(value)
    @patterns = value
  end

  # The pattern as the post's first words, with the company's name filled in.
  def fill(pattern, name) = pattern.sub("{name}", name)

  # The index of the pattern a text opens with, or nil.
  def index_of(text, name)
    start = text.to_s.lstrip
    patterns.index { |pattern| start.start_with?(fill(pattern, name).sub(/[.:]\z/, "")) }
  end

  # The first words of every pattern before the name (let through the name checks as sentence openers).
  def first_words = patterns.filter_map { |pattern| pattern.split("{name}").first.to_s.split.first&.delete(".:,") }.uniq

  # Indexes used by the last RECENT spotlight posts on the platform (any status but cancelled/blocked/failed).
  def recent(platform, except: nil)
    SocialPost.where.not(id: except).where(platform:, subject_type: "Organization").where.not(status: %w[cancelled blocked failed]).order(id: :desc).limit(RECENT).filter_map do |post|
      index_of(post.text, post.subject&.name.to_s)
    end
  end

  # The pattern for the next post: the first one, in order, not used in the last RECENT posts.
  def next_for(platform, except: nil)
    used = recent(platform, except:)
    patterns.each_index.find { |index| used.exclude?(index) } || patterns.each_index.first
  end
end
