# The site's public pages, as the sitemap lists them (#56): the fixed pages,
# the category and tag pages that list someone, and every published company
# and plant. The admin's Where it appears (#166) counts the same list, so the
# two never disagree.
class PublicPages
  # Home, the company list, Privacy, Disclaimer and /bot.
  FIXED = 6

  def companies = Organization.published.select(:slug).order(:slug)

  # { slug => Date } of each company page's last change: the record, or the
  # latest change to anything its page shows (links, roles, technologies,
  # plants, deal terms, news). Only rows the page shows (verified) or has
  # taken off (unpublished) count: a pending or rejected claim changes
  # nothing a visitor sees (Infra). One query, computed once a day.
  def company_lastmods
    Rails.cache.fetch([ "sitemap-company-lastmod", Date.current ], expires_in: 1.day) do
      Organization.published.pluck(:slug, Arel.sql(<<~SQL.squish)).to_h { |slug, at| [ slug, at&.to_date ] }
        GREATEST(organizations.updated_at,
          (SELECT MAX(r.updated_at) FROM relationships r WHERE (r.from_organization_id = organizations.id OR r.to_organization_id = organizations.id) AND r.verification_status IN ('verified', 'unpublished')),
          (SELECT MAX(x.updated_at) FROM organization_roles x WHERE x.organization_id = organizations.id AND x.verification_status IN ('verified', 'unpublished')),
          (SELECT MAX(x.updated_at) FROM organization_technologies x WHERE x.organization_id = organizations.id AND x.verification_status IN ('verified', 'unpublished')),
          (SELECT MAX(x.updated_at) FROM facility_relationships x WHERE x.organization_id = organizations.id AND x.verification_status IN ('verified', 'unpublished')),
          (SELECT MAX(d.updated_at) FROM deal_terms d WHERE d.link_type = 'Organization' AND d.link_id = organizations.id AND d.verification_status IN ('verified', 'unpublished')),
          (SELECT MAX(n.updated_at) FROM news_mentions m JOIN news_items n ON n.id = m.news_item_id
            WHERE m.subject_type = 'Organization' AND m.subject_id = organizations.id AND n.verification_status IN ('verified', 'unpublished')))
      SQL
    end
  end

  # The same for plant and site pages: the site, its units, their links and news.
  def plant_lastmods
    Rails.cache.fetch([ "sitemap-plant-lastmod", Date.current ], expires_in: 1.day) do
      Facility.published.where(parent_id: nil).pluck(:slug, Arel.sql(<<~SQL.squish)).to_h { |slug, at| [ slug, at&.to_date ] }
        GREATEST(facilities.updated_at,
          (SELECT MAX(u.updated_at) FROM facilities u WHERE u.parent_id = facilities.id AND u.verification_status IN ('verified', 'unpublished')),
          (SELECT MAX(x.updated_at) FROM facility_relationships x
            WHERE (x.facility_id = facilities.id OR x.facility_id IN (SELECT u.id FROM facilities u WHERE u.parent_id = facilities.id)) AND x.verification_status IN ('verified', 'unpublished')),
          (SELECT MAX(n.updated_at) FROM news_mentions m JOIN news_items n ON n.id = m.news_item_id
            WHERE m.subject_type = 'Facility' AND m.subject_id = facilities.id AND n.verification_status IN ('verified', 'unpublished')))
      SQL
    end
  end
  def plants = Facility.published.where(parent_id: nil).select(:slug).order(:slug)

  # Buckets that list someone (#281); an empty one isn't linked anywhere.
  # Plants and sites always is.
  def categories
    @categories ||= begin
      counts = DirectoryListing.category_counts
      Category.all.select { |category| category.plants || counts[category.key].to_i.positive? }
    end
  end

  def tags = @tags ||= Tag.all.select { |tag| Organization.where(id: tag.organization_ids).exists? }

  def count = FIXED + categories.size + tags.size + companies.count + plants.count

  # Cards a link preview can draw: one per company, plant and category page
  # (an empty category's page has one too, though the sitemap leaves it
  # out), and the default card every other page shares.
  def link_previews = companies.count + plants.count + Category.all.size + 1
end
