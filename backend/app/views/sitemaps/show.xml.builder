# lastmod on company and plant pages (Infra, 29 Oct): the latest change to
# the record or anything its page shows (PublicPages), as a date.
xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  [ root_url, companies_url, *@categories.map { |category| companies_url(category: category.to_param) },
    *@tags.map { |tag| companies_url(tag: tag.to_param) },
    about_url, privacy_url, disclaimer_url, bot_url ].each do |url|
    xml.url { xml.loc url }
  end
  @companies.each do |company|
    xml.url do
      xml.loc company_url(slug: company.slug)
      (at = @company_lastmods[company.slug]) and xml.lastmod(at.iso8601)
    end
  end
  @plants.each do |plant|
    xml.url do
      xml.loc plant_url(slug: plant.slug)
      (at = @plant_lastmods[plant.slug]) and xml.lastmod(at.iso8601)
    end
  end
end
