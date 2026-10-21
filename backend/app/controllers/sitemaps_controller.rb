# sitemap.xml and robots.txt (#56), built per request so the host is right
# on every deploy (preview URLs and the real domain alike).
class SitemapsController < ApplicationController
  def show
    pages = PublicPages.new
    @companies, @plants, @categories, @tags = pages.companies, pages.plants, pages.categories, pages.tags
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
