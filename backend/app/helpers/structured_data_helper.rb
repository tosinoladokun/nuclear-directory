# schema.org JSON-LD for company and power plant pages (#185), so search
# engines and agents read the facts reliably. It states only what the page
# shows (the profile already hides what no source backs), and lists the page's
# numbered sources as `citation`, in the page's order.
module StructuredDataHelper
  # A <script type="application/ld+json"> for the head. json_escape keeps
  # "</script>" and friends in a name from ending the tag.
  def json_ld_tag(data)
    tag.script(raw(ERB::Util.json_escape(JSON.generate(data))), type: "application/ld+json") # rubocop:disable Rails/OutputSafety
  end

  def company_json_ld(profile, page_url:)
    org = {
      "@type" => "Organization", "@id" => "#{page_url}#organization", "name" => profile.name,
      "legalName" => profile.legal_name.presence, "alternateName" => profile.aliases.presence,
      "description" => profile.description.presence, "url" => linked_website(profile.website),
      "address" => postal_address(profile.hq_city, profile.hq_state), "foundingDate" => profile.founded_year&.to_s,
      "parentOrganization" => profile.parents.map { |link| organization_ref(link.to_organization) }.presence,
      "subOrganization" => profile.subsidiaries.map { |link| organization_ref(link.from_organization) }.presence
    }.compact
    { "@context" => "https://schema.org", "@graph" => [ web_page(profile, page_url, org["@id"]), org ] }
  end

  def plant_json_ld(profile, page_url:)
    properties = [
      property("Type", facility_type_label(profile.facility_type)), property("Status", facility_status_label(profile.status)),
      property("NRC docket", profile.nrc_docket), property("Technology", profile.technologies.join(", ").presence),
      property("Reactor type", profile.reactor_types.join(", ").presence),
      property("Capacity", profile.capacity_mw&.then { |mw| { "@type" => "QuantitativeValue", "value" => mw.to_f, "unitText" => "MW" } })
    ].compact
    place = {
      "@type" => "Place", "@id" => "#{page_url}#place", "name" => profile.name,
      "address" => postal_address(profile.city, profile.state), "additionalProperty" => properties.presence
    }.compact
    { "@context" => "https://schema.org", "@graph" => [ web_page(profile, page_url, place["@id"]), place ] }
  end

  private

  def web_page(profile, page_url, entity_id)
    citations = profile.citations.sources.filter_map do |_number, source|
      next unless (href = safe_source_url(source))

      { "@type" => "CreativeWork", "url" => href, "name" => source.title.presence, "datePublished" => source.published_on&.iso8601 }.compact
    end
    { "@type" => "WebPage", "@id" => "#{page_url}#page", "url" => page_url, "name" => profile.name,
      "dateModified" => profile.verified_at&.to_date&.iso8601, "mainEntity" => { "@id" => entity_id },
      "citation" => citations.presence }.compact
  end

  def organization_ref(organization)
    { "@type" => "Organization", "name" => organization.name, "url" => company_url(slug: organization.slug) }
  end

  def postal_address(city, state)
    return if city.blank? && state.blank?

    { "@type" => "PostalAddress", "addressLocality" => city.presence, "addressRegion" => state.presence, "addressCountry" => "US" }.compact
  end

  def property(name, value)
    { "@type" => "PropertyValue", "name" => name, "value" => value } if value.present?
  end

  def linked_website(website)
    website if website.to_s.match?(%r{\Ahttps?://}i)
  end
end
