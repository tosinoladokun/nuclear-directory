# A candidate as a plain-English claim, for the verifier model to check
# against its source and for the admin to show. Visitors' words (VOICE.md):
# company, not organization; plant, not facility.
#   facility: "There is a plant named "Vogtle 3", with NRC docket 05200025,
#              plant type power reactor, and status operating."
#   facility_relationship: "Southern Nuclear Operating Co. operates the
#              plant Vogtle 3 (NRC docket 05200025)."
module DataQuality::Claim
  RELATIONSHIP_VERBS = {
    "supplies" => "supplies", "invests_in" => "invests in", "funds" => "funds",
    "offtake_with" => "has an offtake agreement with", "subsidiary_of" => "is a subsidiary of",
    "owns" => "owns", "operates" => "operates", "vendor_for" => "is a vendor for", "offtakes_from" => "offtakes from"
  }.freeze
  # Roles in visitors' words (VOICE.md), each with its article: the same
  # phrases as the directory's review labels (Directory::Lookup; a test keeps
  # them in step). The article isn't guessed from the first letter, which
  # would say "an utility". Other roles read "has the role <name>".
  ROLE_PHRASES = {
    "fuel" => "a fuel supplier", "mining" => "a uranium miner", "conversion" => "a uranium converter",
    "enrichment" => "a uranium enricher", "fabrication" => "a fuel fabricator",
    "reactor_vendor" => "a reactor developer", "reactor_services" => "a repair and services company",
    "utility" => "a utility", "operator" => "an operator", "data_center_offtaker" => "a power buyer",
    "coolant" => "a coolant supplier", "molten_salt" => "a molten salt coolant supplier",
    "water" => "a light water coolant supplier", "helium" => "a helium coolant supplier",
    "sodium" => "a sodium coolant supplier", "lead" => "a lead coolant supplier",
    "heavy_water" => "a heavy water supplier", "regulatory_consultant" => "a regulatory consultant",
    "venture_capital" => "a venture capital investor", "government_agency" => "a government agency",
    "national_lab" => "a national lab", "waste_decommissioning" => "a waste and decommissioning company"
  }.freeze
  LABELS = { "nrc_docket" => "NRC docket", "facility_type" => "plant type", "ownership_pct" => "ownership",
    "hq_city" => "headquarters city", "hq_state" => "headquarters state", "capacity_mw" => "capacity",
    "amount_usd" => "amount", "amount_offered_usd" => "amount offered", "external_id" => "external ID", "link_name" => "belongs to",
    "sec_cik" => "SEC CIK" }.freeze
  # A Form D round's fields in its own words (#129): what it sold, and when it first sold.
  ROUND_LABELS = { "amount_usd" => "amount sold", "starts_on" => "first sale on", "external_id" => "filing" }.freeze

  # One sentence: a value that ends in its own full stop ("…: DENE0009054.")
  # doesn't get a second one.
  def self.describe(candidate) = sentence(candidate).sub(/([.!?])\.\z/, '\1')

  def self.sentence(candidate)
    payload = candidate.payload

    case candidate.kind
    when "organization"
      "There is a company named “#{payload['name']}”#{details(payload.except('name'))}."
    when "organization_alias"
      "#{name_of(payload['organization'])} is also known as “#{payload['alias']}”."
    # Enrichment (EIA) names an existing unit in "identify" and sets values on it.
    when "facility"
      if (unit = payload["identify"]).is_a?(Hash)
        values = details(payload.except("identify")).delete_prefix(", with ")
        values.empty? ? "#{unit_name(unit)} is listed." : "#{unit_name(unit)} has #{values}."
      else
        "There is a plant named “#{payload['name']}”#{details(payload.except('name'))}."
      end
    # Links carry every detail approval would publish (ownership %, dates,
    # description), so nothing is published that the verifier didn't check.
    when "facility_relationship"
      "#{name_of(payload['organization'])} #{verb(payload['relationship_type'])} the plant " \
        "#{facility_name(payload['facility'])}#{details(payload.except('organization', 'facility', 'relationship_type'))}."
    when "relationship"
      "#{name_of(payload['from_organization'])} #{verb(payload['relationship_type'])} #{name_of(payload['to_organization'])}" \
        "#{details(payload.except('from_organization', 'to_organization', 'relationship_type'))}."
    when "organization_role"
      role = payload["role"].to_s
      phrase = ROLE_PHRASES[role]
      phrase ? "#{name_of(payload['organization'])} is #{phrase}." : "#{name_of(payload['organization'])} has the role #{humanize(role)}."
    when "organization_technology"
      "#{name_of(payload['organization'])} works on #{humanize(payload['technology'])}."
    # A company's own funding round (#396): every value approval would publish.
    when "deal_term"
      values = payload.except("organization", "link_type", "term_type", "round")
      values = values.transform_keys { |key| ROUND_LABELS.fetch(key, key) } if payload["term_type"] == "funding_round"
      "#{name_of(payload['organization'])} has a #{humanize(payload['term_type'])}#{" (#{payload['round']})" if payload['round'].present?}" \
        "#{details(values)}."
    else
      "#{candidate.kind.humanize}: #{payload.to_json}"
    end
  end

  # "$37,000,000": whole dollars as the filing states them, never rounded to millions.
  def self.dollars(value)
    amount = BigDecimal(value.to_s, exception: false) or return value.to_s
    "$#{ActiveSupport::NumberHelper.number_to_delimited(amount.round(2).to_s('F').delete_suffix('.0'))}"
  end

  def self.details(attributes)
    pairs = attributes.compact_blank.map { |key, value| "#{LABELS.fetch(key) { key.humanize(capitalize: false) }} #{value_text(key, value)}" }
    pairs.empty? ? "" : ", with #{pairs.to_sentence}"
  end

  def self.value_text(key, value)
    case key
    when "facility_type", "status" then humanize(value)
    when "ownership_pct" then "#{value}%"
    when "capacity_mw" then "#{value} MW"
    when "amount_usd", "amount_offered_usd", "amount sold" then dollars(value)
    else value.to_s
    end
  end

  def self.name_of(ends) = ends.is_a?(Hash) ? (ends["name"] || ends["domain"]).to_s : ends.to_s

  def self.facility_name(ends)
    docket = ends.is_a?(Hash) && ends["nrc_docket"]
    docket ? "#{name_of(ends)} (NRC docket #{docket})" : name_of(ends)
  end

  # "Surry unit 1 (VA, EIA plant 3806)"
  def self.unit_name(unit)
    where = [ unit["state"], ("EIA plant #{unit['eia_plant_id']}" if unit["eia_plant_id"].present?) ].compact_blank
    "The plant “#{unit['name']}”#{" unit #{unit['unit']}" if unit['unit'].present?}" \
      "#{" (#{where.join(', ')})" if where.any?}"
  end

  def self.verb(type) = RELATIONSHIP_VERBS.fetch(type.to_s, humanize(type))
  def self.humanize(value) = value.to_s.humanize(capitalize: false)
  private_class_method :sentence, :details, :value_text, :name_of, :facility_name, :unit_name, :verb, :humanize
end
