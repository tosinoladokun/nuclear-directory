# sitemap.xml and robots.txt (#56), built per request so the host is right
# on every deploy (preview URLs and the real domain alike).
class SitemapsController < ApplicationController
  def show
    @companies = Organization.published.select(:slug).order(:slug)
    @plants = Facility.published.where(parent_id: nil).select(:slug).order(:slug)
    # Buckets and tag pages that list someone (#281); an empty one isn't
    # linked anywhere. Plants and sites always is.
    counts = DirectoryListing.category_counts
    @categories = Category.all.select { |category| category.plants || counts[category.key].to_i.positive? }
    @tags = Tag.all.select { |tag| Organization.where(id: tag.organization_ids).exists? }
    expires_in 1.hour, public: true
  end

  def robots
    expires_in 1.day, public: true
    return render plain: "User-agent: *\nDisallow: /\n" if Noindex.enabled?

    render plain: <<~TXT
      User-agent: *
      Disallow: /admin
      Disallow: /corrections
      Disallow: /search
      Disallow: /design

      Sitemap: #{sitemap_url}
    TXT
  end
end
