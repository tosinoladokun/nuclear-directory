# The site's public pages, as the sitemap lists them (#56): the fixed pages,
# the category and tag pages that list someone, and every published company
# and plant. The admin's Where it appears (#166) counts the same list, so the
# two never disagree.
class PublicPages
  # Home, the company list, Privacy, Disclaimer and /bot.
  FIXED = 5

  def companies = Organization.published.select(:slug).order(:slug)
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

  # Pages a link preview card is drawn for: each company, plant and category
  # page, and the default card every other page shares.
  def link_previews = companies.count + plants.count + categories.size + 1
end
