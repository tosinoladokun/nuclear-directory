# Words and small formats the public pages share. The wording follows
# VOICE.md: visitors see "company" and "power plant", never the data model's
# "organization" and "facility". Change a label here and every page follows.
module DirectoryHelper
  # Read left to right: "<from> <verb> <to>", e.g. "Google offtakes from Kairos Power".
  RELATIONSHIP_VERBS = {
    "supplies" => "supplies",
    "invests_in" => "invests in",
    "funds" => "funds",
    "offtake_with" => "offtakes from",
    "subsidiary_of" => "is a subsidiary of"
  }.freeze

  # "<company> <verb> <plant>", e.g. "Westinghouse is the reactor developer for Plant Vogtle".
  FACILITY_RELATIONSHIP_VERBS = {
    "owns" => "owns",
    "operates" => "operates",
    "vendor_for" => "is the reactor developer for",
    "offtakes_from" => "offtakes from"
  }.freeze

  FACILITY_TYPE_LABELS = {
    "power_reactor" => "Power plant",
    "research_reactor" => "Test reactor",
    "fuel_facility" => "Fuel plant",
    "enrichment" => "Enrichment plant",
    "fusion_facility" => "Fusion plant",
    "uranium_mine" => "Uranium mine",
    "mill" => "Uranium mill",
    "other" => "Site"
  }.freeze

  FACILITY_STATUS_LABELS = {
    "operating" => "Operating",
    "not_operating" => "Not operating",
    "under_construction" => "Under construction",
    "planned" => "Planned",
    "shut_down" => "Shut down",
    "decommissioning" => "Being decommissioned"
  }.freeze

  ROLE_LABELS = {
    "fuel" => "Fuel supplier",
    "mining" => "Uranium mining and milling",
    "conversion" => "Uranium conversion",
    "enrichment" => "Enrichment",
    "fabrication" => "Fuel fabrication",
    "reactor_vendor" => "Reactor developer",
    "reactor_services" => "Repair and services",
    "components" => "Component maker",
    "isotopes" => "Isotope producer",
    "waste_decommissioning" => "Waste and decommissioning",
    "utility" => "Utility",
    "operator" => "Plant operator",
    "data_center_offtaker" => "Power buyer",
    "coolant" => "Coolant",
    "regulatory_consultant" => "Regulatory consultant",
    "venture_capital" => "Investor",
    "government_agency" => "Government agency",
    "national_lab" => "National lab",
    "university" => "University",
    "research_organization" => "Research organization",
    "molten_salt" => "Molten salt coolant",
    "water" => "Water coolant",
    "helium" => "Helium coolant",
    "sodium" => "Sodium coolant",
    "lead" => "Lead coolant",
    "heavy_water" => "Heavy water"
  }.freeze

  # Bars filled out of 3, and the word shown beside them.
  CONFIDENCE_LEVELS = [
    [ 0.9, 3, "High" ],
    [ 0.7, 2, "Medium" ],
    [ 0.0, 1, "Low" ]
  ].freeze

  # Public URLs, so views link to pages without knowing the routes.
  def directory_url_for(category: nil, q: nil, **filters)
    companies_path({ category: category&.to_param, q: q.presence }.merge(filters).compact_blank)
  end

  def company_url_for(organization) = company_path(slug: organization.slug)

  # "Report a correction", prefilled with what it's about and where it was.
  CORRECTIONS_EMAIL = "hello@nuclear-directory.org".freeze
  def correction_url_for(subject, page: request.path) = new_correction_path(subject:, page:)

  def correction_mailto(subject, page)
    "mailto:#{CORRECTIONS_EMAIL}?" + { subject: "Correction: #{subject}", body: "Page: #{request.base_url}#{page}\n\nWhat should change:\n" }
      .to_query.gsub("+", "%20")
  end
  def plant_url_for(facility) = plant_path(slug: facility.slug)

  def relationship_verb(type) = RELATIONSHIP_VERBS.fetch(type.to_s)
  def facility_relationship_verb(type) = FACILITY_RELATIONSHIP_VERBS.fetch(type.to_s)
  def facility_type_label(type) = FACILITY_TYPE_LABELS[type.to_s]
  def facility_status_label(status) = FACILITY_STATUS_LABELS[status.to_s]

  # Roles whose parent is shown instead (enrichment under fuel) are left to the caller.
  def role_label(role)
    key = role.respond_to?(:key) ? role.key : role.to_s
    ROLE_LABELS[key] || (role.respond_to?(:name) ? role.name : key.humanize)
  end

  # nil confidence gives nil: show nothing rather than a guess.
  def confidence_level(confidence)
    return if confidence.nil?

    _, bars, word = CONFIDENCE_LEVELS.find { |threshold, *| confidence.to_d >= threshold }
    { bars: bars, word: word }
  end

  # "Kairos Power" => "KP", "X-energy" => "XE", "Westinghouse Electric Company" => "WE".
  def initials(name)
    words = name.to_s.split(/[\s\-]+/).reject { |word| word.casecmp?("the") || word.blank? }
    words.first(2).map { |word| word[0] }.join.upcase
  end

  # "Alameda, CA", "CA" or nil when neither is known.
  def place(city, state)
    [ city.presence, state.presence ].compact.join(", ").presence
  end

  # "Waynesboro, Georgia": the same, with the state's full name, for
  # descriptions people read in search results.
  def full_place(city, state)
    place(city, LinkCard::US_STATES[state.to_s] || state)
  end

  # A plant's <title>, in the words of plant-and-place searches (#291):
  #   "Plant Vogtle, Waynesboro, GA: owners and operator"
  # The place and each of owners and operator only when published.
  def plant_title(profile)
    owners = profile.current_companies_for("owns").any?
    operators = profile.current_companies_for("operates").any?
    who = [ ("owners" if owners), ("operator" if operators) ].compact.join(" and ").presence
    [ [ profile.name, place(profile.city, profile.state) ].compact.join(", "), who ].compact.join(": ")
  end

  # Two sentences, with a full stop between them unless the first has one.
  # A plant's link preview and meta description (#246), from published facts
  # only, each left out when it isn't known:
  #   "Plant Vogtle: Operating power plant in Waynesboro, Georgia. 4 units, 4,536 MW.
  #    Owned by Georgia Power and 3 others; operated by Southern Nuclear."
  # Kept under PREVIEW_LIMIT characters: a long owner list becomes "<first>
  # and <n> others", then the units and capacity go, then owners.
  PREVIEW_LIMIT = 160

  def plant_preview(profile)
    # "Not operating" reads after the place, not before the type: "Power plant in Covert, MI, not operating".
    idle = profile.status == "not_operating"
    status = facility_status_label(profile.status) unless idle
    kind = [ status, (status ? facility_type_label(profile.facility_type)&.downcase : facility_type_label(profile.facility_type)) ]
      .compact.join(" ").presence
    where = full_place(profile.city, profile.state)
    what = kind ? [ kind, (where && "in #{where}") ].compact.join(" ") : (where && "In #{where}")
    what = what ? "#{what}, not operating" : "Not operating" if idle
    units = profile.units.size
    capacity = "#{number_with_precision(profile.capacity_mw, precision: 2, strip_insignificant_zeros: true, delimiter: ",")} MW" if profile.capacity_mw
    size = [ (pluralize(units, "unit") if units.positive?), capacity ].compact.join(", ").presence
    owners = profile.current_companies_for("owns").map(&:name)
    operators = profile.current_companies_for("operates").map(&:name)
    # Lists as the site writes them, without a serial comma ("A, B and C").
    listed = ->(names) { names.to_sentence(last_word_connector: " and ") }
    run_by = ->(owned) { [ (owned && "Owned by #{owned}"), (operators.any? && "operated by #{listed.call(operators)}") ].select(&:itself).join("; ").upcase_first.presence }
    few_owners = owners.many? ? "#{owners.first} and #{pluralize(owners.size - 1, 'other')}" : owners.first

    lines = [
      [ what, size, run_by.call(listed.call(owners).presence) ],
      [ what, size, run_by.call(few_owners) ],
      [ what, nil, run_by.call(few_owners) ],
      [ what, nil, run_by.call(nil) ],
      [ what, nil, nil ]
    ].map do |parts|
      body = parts.compact.map { |part| part.end_with?(".") ? part : "#{part}." }.join(" ")
      body.present? ? "#{profile.name}: #{body}" : profile.name
    end
    lines.find { |line| line.length <= PREVIEW_LIMIT } || lines.last.truncate(PREVIEW_LIMIT, separator: " ")
  end

  # A company's role as a noun for its <title> (#292): "Energy Fuels:
  # uranium miner, plants and deals". Roles not listed use their label.
  TITLE_ROLES = {
    "fuel" => "fuel supplier", "mining" => "uranium miner", "conversion" => "uranium converter",
    "enrichment" => "enrichment company", "fabrication" => "fuel fabricator",
    "reactor_vendor" => "reactor developer", "reactor_services" => "nuclear services company",
    "utility" => "utility", "operator" => "plant operator", "data_center_offtaker" => "power buyer",
    "venture_capital" => "investor"
  }.freeze
  # The whole <title>, " · Nuclear Directory" included, about what search
  # results show before cutting it off.
  TITLE_LIMIT = 70
  SITE_SUFFIX = " · Nuclear Directory"

  # "Helion Energy: fusion developer, investors · Nuclear Directory", from the
  # roles shown and the sections the page has. What the page holds is dropped
  # from the end, then the role, until the whole title fits TITLE_LIMIT; a name
  # too long even alone is kept whole rather than cut.
  def company_title(profile)
    keys = profile.shown_roles.map { |r| r.role.key }
    fusion = profile.technologies.any? { |t| [ t.technology.key, t.technology.parent&.key ].include?("fusion") }
    # The role its category is for, as on its card (LinkCard.for_company), so
    # Kairos Power is a "reactor developer", not "molten salt coolant".
    category_keys = profile.category&.role_keys.to_a
    key = profile.shown_roles.map(&:role).find { |r| ([ r.key, r.parent&.key ] & category_keys).any? }&.key || keys.first
    role = if fusion && keys.include?("reactor_vendor")
      "fusion developer"
    elsif key
      TITLE_ROLES[key] || role_label(key).downcase
    end
    holds = [ ("plants" if profile.plant_links.any?), ("investors" if investors_of(profile).any?), ("deals" if profile.deals.any?) ].compact
    candidates = holds.size.downto(0).map { |n| [ role, holds.first(n).to_sentence(last_word_connector: " and ").presence ].compact.join(", ").presence }
    titles = [ *candidates.map { |about| [ profile.name, about ].compact.join(": ") }, profile.name ].map { |title| "#{title}#{SITE_SUFFIX}" }
    titles.find { |title| title.length <= TITLE_LIMIT } || titles.last
  end

  # A company's meta and link-preview description (#292, #247), within
  # PREVIEW_LIMIT: its one-line description when published, then facts from
  # its plants and deals, each left out when it isn't known or doesn't fit.
  #   "Southern Nuclear: Operates Plant Vogtle and 2 other plants. Legal name:
  #    Southern Nuclear Operating Company, Inc."
  def company_description(profile)
    listed = ->(names, noun = nil) { names.many? ? "#{names.first} and #{pluralize(names.size - 1, [ "other", noun ].compact.join(" "))}" : names.first }
    # Present tense, so only links in effect today (as on the company's card).
    current = ->(l) { (l.started_on.nil? || l.started_on <= Date.current) && (l.ended_on.nil? || l.ended_on > Date.current) }
    places = ->(type) { profile.plant_links.select { |l| l.relationship_type == type && current.call(l) }.map { |l| l.facility.parent || l.facility }.uniq }
    sites = ->(type) { places.call(type).map(&:name) }
    # "plant" only when every one is a published power plant; a mine, a fuel
    # plant or a type that isn't published makes it "site" (VOICE.md).
    noun = ->(type) { places.call(type).all? { |site| profile.plant_facts?(site) && site.facility_type == "power_reactor" } ? "plant" : "site" }
    deals_out = ->(type) { profile.deals.select { |d| d.relationship_type == type && d.from_organization_id == profile.organization.id && current.call(d) }.map { |d| d.to_organization.name }.uniq }
    facts = [
      ("Owns #{listed.call(sites.call('owns'), noun.call('owns'))}" if sites.call("owns").any?),
      ("Operates #{listed.call(sites.call('operates'), noun.call('operates'))}" if sites.call("operates").any?),
      ("Investors include #{listed.call(investors_of(profile))}" if investors_of(profile).any?),
      ("Invests in #{listed.call(deals_out.call('invests_in'))}" if deals_out.call("invests_in").any?),
      ("Supplies #{listed.call(deals_out.call('supplies'))}" if deals_out.call("supplies").any?),
      ("Offtakes from #{listed.call(deals_out.call('offtake_with'))}" if deals_out.call("offtake_with").any?),
      ("Legal name: #{profile.legal_name}" if profile.legal_name.present? && profile.legal_name != profile.name)
    ].compact.map { |fact| fact.end_with?(".") ? fact : "#{fact}." }
    role = profile.shown_roles.first && role_label(profile.shown_roles.first.role)
    lead = profile.description.presence || [ role, place(profile.hq_city, profile.hq_state) ].compact.join(" in ").presence
    # With nothing published yet, still a plain line about the company.
    text = lead ? "#{profile.name}: #{lead.end_with?('.') ? lead : "#{lead}."}" : "#{profile.name}, a company in the US nuclear industry."
    text = text.truncate(PREVIEW_LIMIT, separator: " ") if text.length > PREVIEW_LIMIT
    facts.each do |fact|
      joined = "#{text} #{fact}"
      text = joined if joined.length <= PREVIEW_LIMIT
    end
    text
  end

  # Companies that invest in this one (equity, invests_in), from the deals the
  # page shows and in effect today. Grants and awards (funds) aren't
  # investment (DATA.md).
  def investors_of(profile)
    today = Date.current
    profile.deals.select { |d| d.relationship_type == "invests_in" && d.to_organization_id == profile.organization.id &&
      (d.started_on.nil? || d.started_on <= today) && (d.ended_on.nil? || d.ended_on > today) }
      .map { |d| d.from_organization.name }.uniq
  end

  def sentence_join(first, second)
    first = first.to_s.strip
    first.match?(/[.!?]\z/) ? "#{first} #{second}" : "#{first}. #{second}"
  end

  # Dates in data contexts are ISO; prose uses "October 2024".
  def data_date(date) = date&.to_date&.iso8601
  def prose_month(date) = date&.to_date&.strftime("%B %Y")

  # The URL if it's a web address we can safely link to, else nil. Source
  # URLs come from crawled and imported data, so anything that isn't plain
  # http(s) (e.g. "javascript:") is shown as text, never as a link.
  def safe_source_url(source)
    uri = URI.parse(source.url.to_s.strip)
    source.url.to_s.strip if %w[http https].include?(uri.scheme&.downcase) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  # "kairospower.com" for a source, from its domain or URL.
  # A URL with no host (a bad import such as "javascript:...") reads
  # "unlinked source", so chips and their labels are never blank.
  def source_domain(source)
    source.domain.presence || URI.parse(source.url.to_s).host.to_s.delete_prefix("www.").presence || "unlinked source"
  rescue URI::InvalidURIError
    "unlinked source"
  end
end
