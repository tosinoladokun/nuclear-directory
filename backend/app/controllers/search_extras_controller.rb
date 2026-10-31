# The dressing for instant search in the browser (#696): the icon squares the rows show and the topic pages a typed word
# can jump to. Small, the same for everyone, so no session cookie and a shared cache may keep it. The people-facing index
# is SearchIndexesController's.
class SearchExtrasController < ApplicationController
  # Words people type for a topic that isn't its tag's name.
  SYNONYMS = { "smr" => %w[smrs small\ modular], "fusion" => %w[tokamak stellarator], "enrichment" => %w[haleu leu centrifuge],
    "isotopes" => %w[radioisotope radioisotopes medical], "fuel-fabrication" => %w[triso fabricator], "uranium" => %w[mining miner mines],
    "national-labs" => %w[lab labs laboratory laboratories], "data-center-buyers" => %w[hyperscaler hyperscalers datacenter] }.freeze

  def show
    request.session_options[:skip] = true
    expires_in 1.hour, public: true
    render json: Rails.cache.fetch("search_extras", expires_in: 1.hour) { payload }
  end

  private
    def payload
      counted = Tag.all.map { |tag| [ tag, Organization.published.where(id: tag.organization_ids).count ] }.select { |_, count| count.positive? }
      tags = counted.sort_by { |tag, count| [ -count, tag.key ] }.map do |tag, count|
        { s: tag.key, n: tag.name, a: SYNONYMS.fetch(tag.key, []), c: count, i: icon_for(tag) }
      end
      names = (tags.map { |tag| tag[:i] } + Dir.children(IconHelper::ND_ICON_ROOT).map { |file| file.delete_suffix(".svg") }).uniq
      icons = names.to_h { |name| [ name, helpers.icon(name, set: IconHelper::ND_ICON_ROOT.join("#{name}.svg").file? ? :nd : :phosphor) ] }
      icons["buildings"] = helpers.icon("buildings")
      # Plant rows draw their icon at 20px, company rows at 16px (as the server's rows do).
      names.grep(/\Asite-/).each { |name| icons["#{name}@20"] = helpers.icon(name, set: :nd, size: 20) }
      { icons:, tags: }
    end

    # The icon a tag's chip carries on a company (DirectoryHelper#tag_square, as a name).
    def icon_for(tag)
      if tag.role_key
        keys = [ tag.role_key, Role.find_by(key: tag.role_key)&.parent&.key ].compact
        bucket = Category.buckets.find { |category| (category.role_keys & keys).any? }
        bucket ? (bucket.plants ? "site-plant" : "bucket-#{bucket.key}") : "buildings"
      else
        DirectoryHelper::TECHNOLOGY_ICONS[tag.technology_key] || "site-plant"
      end
    end
end
