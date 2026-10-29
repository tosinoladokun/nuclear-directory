# No lastmod: a page changes when any of its facts or sources does, and the
# records' own timestamps don't track that.
xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  [ root_url, companies_url, *@categories.map { |category| companies_url(category: category.to_param) },
    *@tags.map { |tag| companies_url(tag: tag.to_param) },
    about_url, data_url, privacy_url, disclaimer_url, bot_url,
    *@companies.map { |company| company_url(slug: company.slug) },
    *@plants.map { |plant| plant_url(slug: plant.slug) } ].each do |url|
    xml.url { xml.loc url }
  end
end
