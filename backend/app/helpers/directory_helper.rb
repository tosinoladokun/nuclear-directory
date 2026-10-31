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

  # The chip words on the plants list; "Restart under review" waits for a status of that name in the data.
  STATUS_CHIP_LABELS = FACILITY_STATUS_LABELS.merge("restart_under_review" => "Restart under review", "shut_down" => "Shut down").freeze
  def status_chip_label(key) = STATUS_CHIP_LABELS[key.to_s]

  REACTOR_TYPE_LABELS = {
    "PWR" => "Pressurized water (PWR)", "BWR" => "Boiling water (BWR)", "AP1000" => "Pressurized water (AP1000)",
    "SMR" => "Small modular (SMR)", "HTGR" => "High-temperature gas (HTGR)", "FUSION" => "Fusion"
  }.freeze

  ROLE_LABELS = {
    "fuel" => "Fuel supplier",
    "mining" => "Uranium mining and milling",
    "conversion" => "Uranium conversion",
    "enrichment" => "Enrichment",
    "fabrication" => "Fuel fabrication",
    "reactor_vendor" => "Reactor designer",
    "project_developer" => "Project developer",
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
  # A company page groups its deals under a label that carries the verb, so a
  # row is just the other company (Design, 27 Oct). Key: [type, from this company?].
  DEAL_GROUP_LABELS = {
    [ "funds", false ] => "Funded by", [ "funds", true ] => "Funds",
    [ "invests_in", false ] => "Investors", [ "invests_in", true ] => "Invests in",
    [ "offtake_with", false ] => "Power buyers", [ "offtake_with", true ] => "Buys power from",
    [ "supplies", false ] => "Suppliers", [ "supplies", true ] => "Customers"
  }.freeze
  def deal_group_label(type, from_us) = DEAL_GROUP_LABELS.fetch([ type.to_s, from_us ]) { relationship_verb(type).capitalize }
  def facility_relationship_verb(type) = FACILITY_RELATIONSHIP_VERBS.fetch(type.to_s)
  FACILITY_ROLE_NOUNS = { "owns" => "owner", "operates" => "operator", "vendor_for" => "reactor developer", "offtakes_from" => "offtaker" }.freeze
  def facility_role_noun(type) = FACILITY_ROLE_NOUNS.fetch(type.to_s, type.to_s.humanize.downcase)
  def facility_type_label(type) = FACILITY_TYPE_LABELS[type.to_s]
  def facility_status_label(status) = FACILITY_STATUS_LABELS[status.to_s]

  # The line icon for a kind of site (icons/nd, Design's mapping, #281): by
  # facility type; a power plant by its reactors' types (BWR, PWR, else an
  # advanced design, as is a planned or under-construction one with no
  # PWR or BWR, like Kemmerer); a site being decommissioned as a waste
  # site; anything unknown as a plain plant.
  def site_icon_name(facility_type, reactor_types: [], status: nil)
    return "site-waste" if status.to_s == "decommissioning"

    case facility_type.to_s
    when "power_reactor"
      types = reactor_types.compact_blank.map(&:upcase)
      bwr, pwr = types.any? { |type| type.include?("BWR") }, types.any? { |type| type.match?(/PWR|AP1000/) }
      if bwr && pwr then "site-plant" # mixed: the generic power plant
      elsif bwr then "site-bwr"
      elsif pwr then "site-pwr"
      elsif types.any? || status.to_s.in?(%w[planned under_construction]) then "site-advanced"
      else "site-plant"
      end
    when "research_reactor" then "site-research"
    when "fusion_facility" then "site-fusion"
    when "uranium_mine", "mill" then "site-mine"
    when "enrichment" then "site-enrichment"
    when "fuel_facility" then "site-fuel"
    else "site-plant"
    end
  end

  # A bucket's icon and the class that gives it the bucket's colours.
  def bucket_icon(category, size: 16)
    icon(category.plants ? "site-plant" : "bucket-#{category.key}", set: :nd, size:)
  end

  def bucket_class(category) = ("nd-bucket--#{category.key}" unless category.plants)

  # The tags under a company's summary, each with an icon (Tosin, 27 Oct): a role carries its
  # category's icon and colour ("Fuel supplier" the fuel can), a technology the closest site icon.
  # [{ text:, icon:, bucket: }, ...]
  TECHNOLOGY_ICONS = { "fusion" => "site-fusion", "smr" => "site-advanced" }.freeze
  def company_tags(profile)
    roles = profile.shown_roles.map do |link|
      keys = [ link.role.key, link.role.parent&.key ].compact
      bucket = Category.buckets.find { |category| (category.role_keys & keys).any? }
      { text: role_label(link.role), icon: (bucket_icon(bucket, size: 16) if bucket), bucket: }
    end
    techs = profile.technologies.map do |link|
      tech = link.technology
      name = TECHNOLOGY_ICONS[tech.key] || TECHNOLOGY_ICONS[tech.parent&.key] || "site-plant"
      { text: tech.name, icon: icon(name, set: :nd, size: 16), bucket: nil }
    end
    roles + techs
  end

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

  COUNTRY_NAMES = {
    "US" => "United States", "CA" => "Canada", "MX" => "Mexico", "GB" => "United Kingdom", "FR" => "France", "DE" => "Germany",
    "ES" => "Spain", "IT" => "Italy", "NL" => "Netherlands", "BE" => "Belgium", "CH" => "Switzerland", "SE" => "Sweden",
    "FI" => "Finland", "NO" => "Norway", "DK" => "Denmark", "PL" => "Poland", "CZ" => "Czechia", "SK" => "Slovakia",
    "HU" => "Hungary", "RO" => "Romania", "BG" => "Bulgaria", "UA" => "Ukraine", "RU" => "Russia", "TR" => "Turkey",
    "JP" => "Japan", "KR" => "South Korea", "CN" => "China", "TW" => "Taiwan", "IN" => "India", "PK" => "Pakistan",
    "AE" => "United Arab Emirates", "SA" => "Saudi Arabia", "EG" => "Egypt", "ZA" => "South Africa", "AU" => "Australia",
    "ID" => "Indonesia", "AR" => "Argentina", "BR" => "Brazil", "KZ" => "Kazakhstan", "IE" => "Ireland", "AT" => "Austria"
  }.freeze

  # Where something is, written one way everywhere (#558): rows, key facts,
  # search, map labels.
  #   US:            "Bethesda, MD" (the state abbreviated, a full name too)
  #   outside the US: "Courbevoie, France" (the country in full)
  #   a state alone: "Georgia" (in full, never a lone code)
  # Never a street address or ZIP code. nil when nothing is known.
  def location(city, state = nil, country: "US")
    city = city.to_s.squish.presence
    state = state.to_s.squish.presence
    code = country.to_s.strip.presence || "US"
    if code.upcase == "US" || code.casecmp?("United States")
      abbr = LinkCard::US_STATES.key?(state.to_s.upcase) ? state.upcase : LinkCard::US_STATES.find { |_c, full| full.casecmp?(state.to_s) }&.first
      return [ city, abbr || state ].compact.join(", ").presence if city
      return (LinkCard::US_STATES[abbr] || state) if state

      nil
    else
      name = COUNTRY_NAMES[code.upcase] || (TZInfo::Country.get(code.upcase).name if code.match?(/\A[A-Za-z]{2}\z/) && TZInfo::Country.all_codes.include?(code.upcase)) || code
      [ city, name ].compact.join(", ")
    end
  end

  # "Waynesboro, Georgia": the same, with the state's full name, for
  # descriptions people read in search results.
  def full_place(city, state)
    place(city, LinkCard::US_STATES[state.to_s] || state)
  end

  # A plant's <title> (Tosin, 29 Oct), in the words of ownership searches: "Plant Vogtle: owners, operator and
  # deals | Nuclear Directory". Only the sections the page has.
  def plant_title(profile)
    sections = [ ("owners" if profile.current_companies_for("owns").any?), ("operator" if profile.current_companies_for("operates").any?),
      ("deals" if plant_deal_companies(profile).any?) ].compact
    seo_title(profile.name, sections)
  end

  # Power buyers with a signed deal: a framework or MOU isn't a deal (DealStage, DATA.md).
  def plant_deal_companies(profile)
    profile.links.select { |link| link.relationship_type == "offtakes_from" && link.stage.nil? }.map(&:organization).uniq
  end

  # "Name: a, b and c | Nuclear Directory" within SEO_TITLE_LIMIT: first the suffix goes, then the last section,
  # until it fits; a name too long even alone is kept whole.
  SEO_TITLE_LIMIT = 60
  SEO_SUFFIX = " | Nuclear Directory"
  def seo_title(name, sections)
    candidates = sections.size.downto(0).flat_map do |n|
      body = [ name, sections.first(n).to_sentence(last_word_connector: " and ", two_words_connector: " and ").presence ].compact.join(": ")
      [ "#{body}#{SEO_SUFFIX}", body ]
    end
    candidates.find { |title| title.length <= SEO_TITLE_LIMIT } || candidates.last
  end

  # "3 owners, 1 operator, 2 deals" for a meta description: a count only when it is above zero.
  def counted(*pairs) = pairs.filter_map { |count, noun| pluralize(count, noun) if count.to_i.positive? }

  # A list value ("A, B, C", names possibly links) split before its last
  # item, so that item can stay on a line with its source numbers. Only a
  # ", " between items counts, never one inside a name or a link ("Southern
  # Nuclear Operating Co., Inc."). Only a list of two or more linked names
  # counts: a single value with a comma ("Baton Rouge Metropolitan Area, LA")
  # isn't one. Returns [head, last] as HTML, or nil when it isn't a list.
  def split_last_item(value)
    return unless value.html_safe?

    nodes = Nokogiri::HTML::DocumentFragment.parse(value.to_s).children.to_a
    return if nodes.count(&:element?) < 2
    index = nodes.rindex { |node| node.text? && node.text.include?(", ") }
    return unless index

    # A name before the last can still be longer than the column: it may end
    # in "…", so it carries its full name (Tosin's no-wrap rule).
    nodes[0...index].each do |node|
      next unless node.element?

      node["title"] ||= node.text.squish
      node["data-truncate"] = ""
    end
    before, _, after = nodes[index].text.rpartition(", ")
    escape = ->(text) { ERB::Util.html_escape(text).to_str }
    render = ->(list) { list.map { |node| node.text? ? escape.(node.text) : node.to_html }.join }
    head = render.(nodes[0...index]) + escape.(before) + ", "
    last = escape.(after) + render.(nodes[(index + 1)..])
    [ head.html_safe, last.html_safe ] # rubocop:disable Rails/OutputSafety
  end

  UNIT_STATUS_ORDER = %w[operating not_operating under_construction planned shut_down decommissioning].freeze

  # The 32px category square beside a deal's other company (#556): its first
  # category's icon on its tint, else a plain building.
  def company_square(organization, category: nil)
    tag.span(category ? bucket_icon(category) : icon("buildings"), class: [ "nd-catsq", (bucket_class(category) if category) ], aria: { hidden: true })
  end

  # The plant page's one-sentence owner and operator line (#557), from sourced, current owns and operates
  # links only; nothing inferred, never "owner unknown". Each name links to its company. Phones show the first
  # two owners and "and N others" (narrow: true).
  def plant_owner_sentence(profile, narrow: false)
    owners = profile.current_companies_for("owns")
    operators = profile.current_companies_for("operates")
    names = lambda do |orgs, limit = nil|
      shown = limit && orgs.size > limit + 1 ? orgs.first(limit) : orgs
      links = shown.map { |org| link_to(org.name, company_url_for(org), class: "nd-link") }
      links << "#{orgs.size - shown.size} others" if shown.size < orgs.size
      links.size > 1 ? safe_join([ safe_join(links[0..-2], ", "), " and ", links.last ]) : links.first
    end
    limit = (2 if narrow)
    if owners.one? && operators == owners then safe_join([ "Owned and operated by ", names.(owners), "." ])
    else
      parts = []
      parts << safe_join([ "Owned by ", names.(owners, limit), "." ]) if owners.any?
      parts << safe_join([ "Operated by ", names.(operators, limit), ((", a different company" if owners.any? && (operators & owners).empty?)), "." ].compact) if operators.any?
      safe_join(parts, " ") if parts.any?
    end
  end

  PLANT_VERBS = { "owns" => "owns", "operates" => "operates", "vendor_for" => "is the reactor developer", "offtakes_from" => "buys power" }.freeze
  def plant_verb(type) = PLANT_VERBS.fetch(type.to_s)

  # How a company name fits its column (#558): 15px up to `full` characters, then 13px, then its
  # short name if it has one; an ellipsis (with the full name in title) is the last resort.
  # A deal row's name column is 240px; a list's is 300px, so every name in a list but the
  # rare longest keeps one size (Tosin, 28 Oct). [text, small?]
  LINE_NAME_FULL = 26
  LINE_NAME_SMALL = 31
  LIST_NAME_FULL = 33
  LIST_NAME_SMALL = 38
  def line_name(name, short_name = nil, full: LINE_NAME_FULL, small: LINE_NAME_SMALL)
    return [ name, false ] if name.length <= full
    return [ name, true ] if name.length <= small
    return [ short_name, true ] if short_name.present? && short_name.length <= small

    [ name, true ]
  end

  STATUS_MARKS = {
    "operating" => "filled", "not_operating" => "open", "shut_down" => "open", "decommissioning" => "open",
    "restart_under_review" => "dashed", "under_construction" => "half", "planned" => "dotted"
  }.freeze

  # The mark class for a status (#558): the word always shows beside it.
  def status_mark_kind(status) = STATUS_MARKS.fetch(status.to_s, "open")

  # A plant's units by status, operating first, leaving out statuses no
  # unit has (PM, 16 Oct): "4 operating units", "2 operating units,
  # 1 being decommissioned", "1 unit, not operating", "3 units: 2 shut
  # down, 1 being decommissioned". A unit with no stated status counts as
  # "not stated"; with only those, just the number. noun: "reactor" on
  # link cards. shown_status: the plant's own status, when the same line
  # already says it; if every unit shares it, only the number is given
  # ("Operating · 4 units", not "Operating · 4 operating units").
  def units_summary(statuses, noun: "unit", shown_status: nil)
    return if statuses.empty?
    return pluralize(statuses.size, noun) if shown_status.present? && statuses.all?(shown_status.to_s)

    groups = statuses.map(&:presence).tally.sort_by { |status, _| UNIT_STATUS_ORDER.index(status) || UNIT_STATUS_ORDER.size }
    parts = groups.map do |status, count|
      status == "operating" ? pluralize(count, "operating #{noun}") : "#{count} #{status ? facility_status_label(status).downcase : "not stated"}"
    end
    return parts.join(", ") if groups.first.first == "operating"

    total = pluralize(statuses.size, noun)
    return total if groups.one? && groups.first.first.nil?

    groups.one? ? "#{total}, #{parts.first.delete_prefix("#{statuses.size} ")}" : "#{total}: #{parts.join(", ")}"
  end

  # Two sentences, with a full stop between them unless the first has one.
  # A plant's link preview and meta description (#246), from published facts
  # only, each left out when it isn't known:
  #   "Plant Vogtle: Operating power plant in Waynesboro, Georgia. 4 operating units, 4,536 MW.
  #    Owned by Georgia Power and 3 others; operated by Southern Nuclear."
  # Kept under PREVIEW_LIMIT characters: a long owner list becomes "<first>
  # and <n> others", then the units and capacity go, then owners.
  PREVIEW_LIMIT = 160

  # What a plant is and how big: ["Operating power plant in Waynesboro, GA", "4 units, 4,468 MW"] (either may be nil).
  def plant_what_and_size(profile)
    # "Not operating" reads after the place, not before the type: "Power plant in Covert, MI, not operating".
    idle = profile.status == "not_operating"
    status = facility_status_label(profile.status) unless idle
    kind = [ status, (status ? facility_type_label(profile.facility_type)&.downcase : facility_type_label(profile.facility_type)) ]
      .compact.join(" ").presence
    where = full_place(profile.city, profile.state)
    what = kind ? [ kind, (where && "in #{where}") ].compact.join(" ") : (where && "In #{where}")
    what = what ? "#{what}, not operating" : "Not operating" if idle
    capacity = "#{number_with_precision(profile.capacity_mw, precision: 2, strip_insignificant_zeros: true, delimiter: ",")} MW" if profile.capacity_mw
    [ what, [ units_summary(profile.units.map(&:status), shown_status: profile.status), capacity ].compact.join(", ").presence ]
  end

  def plant_preview_lead(profile)
    what, size = plant_what_and_size(profile)
    body = [ what, size ].compact.map { |part| part.end_with?(".") ? part : "#{part}." }.join(" ")
    body.present? ? "#{profile.name}: #{body}" : profile.name
  end

  def plant_preview(profile)
    what, size = plant_what_and_size(profile)
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
  # A company's <title> (Tosin, 29 Oct): "Oklo: partners, customers, investors and plants | Nuclear Directory",
  # naming only the sections the page has (see seo_title for how it is cut to fit).
  def company_title(profile)
    me = profile.organization.id
    customers = profile.deals.any? { |d| (d.relationship_type == "supplies" && d.from_organization_id == me) || (d.relationship_type == "offtake_with" && d.to_organization_id == me) }
    partners = profile.deals.any? { |d| !(d.relationship_type == "invests_in" && d.to_organization_id == me) }
    seo_title(profile.name, [ ("partners" if partners), ("customers" if customers), ("investors" if investors_of(profile).any?),
      (company_places_noun(profile).pluralize if profile.plant_links.any?) ].compact)
  end

  # "plant" only when every site the company is linked to is a published power plant; a mine or a fuel plant makes
  # them "sites" (VOICE.md), as in company_description.
  def company_places_noun(profile)
    sites = company_current_sites(profile)
    sites.all? { |site| profile.plant_facts?(site) && site.facility_type == "power_reactor" } ? "plant" : "site"
  end

  # The sites a company is linked to today: a link that has ended or not yet started isn't one (as company_description).
  def company_current_sites(profile)
    profile.plant_links.select { |l| (l.started_on.nil? || l.started_on <= Date.current) && (l.ended_on.nil? || l.ended_on > Date.current) }
      .map { |l| l.facility.parent || l.facility }.uniq
  end

  # How a description that isn't a signed deal starts (the connections map's rule, #363).
  NOT_SIGNED_DEAL = [ "MOU", "Framework", "Term sheet", "Binding term sheet", "Letter of intent", "Non-binding", "Preorder", "Option",
    "Conditional", "Announced plan", "Agreement to explore", "Partnership", "Strategic agreement", "Prepayment" ].freeze

  # Signed supply and power deals, as the connections map counts arrows: a power deal with verified terms is signed when a
  # term counts (agreement, status and conditions say so), else its words must say "Signed"; any other deal unless it starts
  # with an earlier stage or is pending. A framework or MOU, an announced or conditional one, and any investment or funding
  # (counted as investors) are not.
  def company_signed_deals(profile)
    profile.counted_deals.select do |deal|
      next false unless %w[supplies offtake_with].include?(deal.relationship_type)

      terms = deal.deal_terms.select { |term| term.verification_status == "verified" }
      text = deal.description.to_s.strip
      if deal.relationship_type == "offtake_with"
        terms.any? ? terms.any?(&:counted?) : text.match?(/\ASigned\b/i)
      else
        NOT_SIGNED_DEAL.none? { |label| text.match?(/\A#{Regexp.escape(label)}\b/i) } && !text.match?(/\bpending\b/i)
      end
    end
  end

  # What a company is, as a noun phrase for a sentence; only roles with a plain company noun (the title's words).
  COMPANY_NOUNS = TITLE_ROLES.merge(
    "project_developer" => "project developer", "components" => "component maker", "isotopes" => "isotope producer",
    "waste_decommissioning" => "waste and decommissioning company", "regulatory_consultant" => "regulatory consultant",
    "government_agency" => "government agency", "national_lab" => "national laboratory", "research_organization" => "research organization",
    "university" => "university"
  ).freeze

  # One factual sentence for a company page with no written description, built only from published facts (Outcome 30 Nov,
  # thin pages): "Oklo is a reactor developer in Santa Clara, CA, with 3 deals and 2 sites." No adjectives; nil when the page
  # has nothing to say yet (no role, place, deal or site), so a bare page stays bare.
  def company_summary(profile)
    return if profile.description.present?

    noun = profile.shown_roles.filter_map { |link| COMPANY_NOUNS[link.role.key] || COMPANY_NOUNS[link.role.parent&.key] }.first
    where = location(profile.hq_city, profile.hq_state, country: (profile.organization.country_code if profile.sourced?))
    sites = company_current_sites(profile).size
    deals = company_signed_deals(profile).size
    with = [ (pluralize(deals, "deal") if deals.positive?), (pluralize(sites, company_places_noun(profile)) if sites.positive?) ].compact.to_sentence(two_words_connector: " and ", last_word_connector: " and ")
    # Nothing beyond the title: a bare role noun, or "a company with 1 plant" (no role, no place), adds nothing.
    return if where.blank? && (noun.nil? || with.blank?)

    kind = noun ? "#{noun.match?(/\A(?:[aeio]|un(?!i))/i) ? "an" : "a"} #{noun}" : "a company"
    "#{profile.name} is #{kind}#{" in #{where}" if where}#{", with #{with}" if with.present? && where}#{" with #{with}" if with.present? && !where}."
  end

  # The meta description of a company (Tosin, 29 Oct): its one-line description, then what the page counts:
  # "Oklo: Develops advanced fission power plants. 3 plants, 2 deals." With no description, the summary sentence, then only
  # the counts it doesn't already say (investors). Link previews keep company_description.
  def company_meta_description(profile)
    lead = profile.description.presence
    summary = company_summary(profile)
    head = if lead then "#{profile.name}: #{lead.end_with?('.') ? lead : "#{lead}."}"
    else summary || "#{profile.name}, a company in the US nuclear industry."
    end
    head = head.truncate(PREVIEW_LIMIT, separator: " ") if head.length > PREVIEW_LIMIT
    investors = [ investors_of(profile).size, "investor" ]
    counts = if lead.nil? && summary
      counted(investors)
    else
      counted([ company_current_sites(profile).size, company_places_noun(profile) ], [ company_signed_deals(profile).size, "deal" ], investors)
    end
    fit_counts(head, counts)
  end

  # The description with as many counts as fit PREVIEW_LIMIT, in order, dropping from the end.
  def fit_counts(head, counts)
    counts.size.downto(0).each do |n|
      text = n.zero? ? head : "#{head} #{counts.first(n).join(', ')}."
      return text if text.length <= PREVIEW_LIMIT
    end
    head.truncate(PREVIEW_LIMIT, separator: " ")
  end

  # A plant's meta description: what it is and where, then "2 owners, 1 operator, 3 deals".
  def plant_meta_description(profile)
    base = plant_preview_lead(profile)
    counts = counted([ profile.current_companies_for("owns").size, "owner" ], [ profile.current_companies_for("operates").size, "operator" ],
      [ plant_deal_companies(profile).size, "deal" ])
    fit_counts(base, counts)
  end

  # A company's meta and link-preview description (#292, #247), within
  # PREVIEW_LIMIT: its one-line description when published, then facts from
  # its plants and deals, each left out when it isn't known or doesn't fit.
  #   "Southern Nuclear: Operates Plant Vogtle and 2 other plants. Legal name:
  #    Southern Nuclear Operating Company, Inc."
  # "3 · 1 framework" (#487, Design): signed deals counted, staged ones noted.
  def deal_count(profile)
    staged = profile.deals.filter_map(&:stage).tally
    [ profile.counted_deals.size, ("#{staged['framework']} framework" if staged["framework"]),
      ("#{staged['non_binding']} not binding" if staged["non_binding"]) ].compact.join(" · ")
  end

  def company_description(profile)
    listed = ->(names, noun = nil) { names.many? ? "#{names.first} and #{pluralize(names.size - 1, [ "other", noun ].compact.join(" "))}" : names.first }
    # Present tense, so only links in effect today (as on the company's card).
    current = ->(l) { (l.started_on.nil? || l.started_on <= Date.current) && (l.ended_on.nil? || l.ended_on > Date.current) }
    places = ->(type) { profile.plant_links.select { |l| l.relationship_type == type && current.call(l) }.map { |l| l.facility.parent || l.facility }.uniq }
    sites = ->(type) { places.call(type).map(&:name) }
    # "plant" only when every one is a published power plant; a mine, a fuel
    # plant or a type that isn't published makes it "site" (VOICE.md).
    noun = ->(type) { places.call(type).all? { |site| profile.plant_facts?(site) && site.facility_type == "power_reactor" } ? "plant" : "site" }
    # Signed deals said flat; a framework or non-binding one says so (#487).
    deals_out = ->(type) { profile.counted_deals.select { |d| d.relationship_type == type && d.from_organization_id == profile.organization.id && current.call(d) }.map { |d| d.to_organization.name }.uniq }
    staged_out = ->(stage) { profile.deals.select { |d| d.stage == stage && d.relationship_type == "offtake_with" && d.from_organization_id == profile.organization.id && current.call(d) }.map { |d| d.to_organization.name }.uniq }
    facts = [
      ("Owns #{listed.call(sites.call('owns'), noun.call('owns'))}" if sites.call("owns").any?),
      ("Operates #{listed.call(sites.call('operates'), noun.call('operates'))}" if sites.call("operates").any?),
      ("Investors include #{listed.call(investors_of(profile))}" if investors_of(profile).any?),
      ("Invests in #{listed.call(deals_out.call('invests_in'))}" if deals_out.call("invests_in").any?),
      ("Supplies #{listed.call(deals_out.call('supplies'))}" if deals_out.call("supplies").any?),
      ("Offtakes from #{listed.call(deals_out.call('offtake_with'))}" if deals_out.call("offtake_with").any?),
      ("Framework offtake with #{listed.call(staged_out.call('framework'))}" if staged_out.call("framework").any?),
      ("Non-binding offtake with #{listed.call(staged_out.call('non_binding'))}" if staged_out.call("non_binding").any?),
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

  # The publisher of a news item for the Latest rows. A URL URI can't parse (e.g. a non-ASCII path) still gets its host as text; it just isn't linked.
  def news_publisher(item)
    host = (URI.parse(item.url.to_s.strip).host rescue nil) || item.url.to_s[%r{\Ahttps?://([^/?#]+)}i, 1]
    host.to_s.downcase.delete_prefix("www.").presence || "source"
  end

  # "kairospower.com" for a source, from its domain or URL.
  # A URL with no host (a bad import such as "javascript:...") reads
  # "unlinked source", so chips and their labels are never blank.
  # A news item's headline for "Latest" (#137): its plain headline when it has one, else its title (an agency notice's
  # title can run long). try: the column comes with Data Quality's headline work.
  # NewsItem#display_title (#683) is the plain headline, at most 80 characters, else the title.
  def news_headline(item) = item.try(:display_title).presence || item.try(:headline).presence || item.title

  def source_domain(source)
    source.domain.presence || URI.parse(source.url.to_s).host.to_s.delete_prefix("www.").presence || "unlinked source"
  rescue URI::InvalidURIError
    "unlinked source"
  end

  # #200: append utm_source=nuclear-directory&utm_medium=referral (and
  # optionally utm_campaign) to outbound company website links at render
  # time, so companies can see in their own analytics that visitors came
  # from here. Only for company websites; source citations stay exactly as
  # cited. Preserves utm_* a URL already carries, and anything that isn't
  # plain http(s) is returned unchanged.
  def with_referral_utm(url, campaign: nil)
    return url if url.blank?

    uri = URI.parse(url.to_s.strip)
    return url unless %w[http https].include?(uri.scheme&.downcase) && uri.host.present?

    keys = uri.query.to_s.split("&").map { |pair| CGI.unescape(pair.split("=", 2).first.to_s.b).force_encoding(Encoding::UTF_8).scrub }
    added = []
    added << [ "utm_source", "nuclear-directory" ] unless keys.include?("utm_source")
    added << [ "utm_medium", "referral" ] unless keys.include?("utm_medium")
    added << [ "utm_campaign", campaign ] if campaign && !keys.include?("utm_campaign")
    return url if added.empty?

    # The existing query is kept byte for byte; only the missing tags are appended.
    uri.query = [ uri.query.presence, URI.encode_www_form(added) ].compact.join("&")
    uri.to_s
  rescue URI::InvalidURIError
    url
  end
end
