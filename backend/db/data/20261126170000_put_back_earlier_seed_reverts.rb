# #947 follow-up: seed runs from 21 Oct to 21 Nov wrote their files' null and older values over fields Tosin had
# approved, before #948's guard existed. Data Quality reconciled every such write one by one (dq-947-reconcile, 25 Nov:
# 59 fields, 50 put back, 9 kept because the approval was wrong for the record) and listed the 50 (dq-947-put-back.json).
# This puts back the value he approved for each, with no new approval: his approval events and their claims stand.
#
# The seed files now hold the approved descriptions (this PR); a null in a file no longer clears a value (#948). So
# after this step, the seed agrees with every field it restores.
#
# Pinned on each seed event as Data Quality read it in production: its record, and each field's approved value (the
# event's "from") and the seed's (its "to"). A field is put back only while the record still holds the seed's value.
# One that already holds the approved value (Oglethorpe's legal name, put back by the 26 Nov seed run) is said and
# skipped; one that holds anything else was decided again and is left, and said. A record no longer verified is left.
class PutBackEarlierSeedReverts < DeployData::Migration
  BY = "human:tosin"
  # [seed event, record type, record id, { field => [approved, seed's value, approval event] }]
  WRITES = [
    [ 2841, "Relationship", 50, { "description" => [ "Conditional HALEU allocation, round 1 (April 9, 2025)", "Conditional commitment (Apr 2025) to provide HALEU from DOE sources (first-round HALEU allocation); contracting to follow.", 2754 ] } ], # us-department-of-energy -> terrapower (supplies)
    [ 2842, "Relationship", 51, { "description" => [ "Conditional HALEU allocation, round 1 (April 9, 2025)", "Conditional HALEU allocation (Apr 2025), first round.", 2756 ] } ], # us-department-of-energy -> kairos-power (supplies)
    [ 2843, "Relationship", 52, { "description" => [ "Conditional HALEU allocation, round 1 (April 9, 2025)", "Conditional HALEU allocation (Apr 2025), first round.", 2757 ] } ], # us-department-of-energy -> triso-x (supplies)
    [ 2844, "Relationship", 53, { "description" => [ "Conditional HALEU allocation, round 1 (April 9, 2025)", "Conditional HALEU allocation (Apr 2025), first round.", 2755 ] } ], # us-department-of-energy -> westinghouse-electric-company (supplies)
    [ 2994, "Organization", 96, { "hq_city" => [ "Helenwood", nil, 2987 ], "hq_state" => [ "TN", nil, 2987 ] } ], # container-technologies-industries
    [ 3242, "Organization", 136, { "short_description" => [ "Superconducting cables, fusion magnets", "Cable technology for magnets", 3121 ] } ], # advanced-conductor-technologies
    [ 3243, "Organization", 2, { "hq_city" => [ "Seattle", nil, 3097 ], "hq_state" => [ "WA", nil, 3097 ] } ], # amazon
    [ 3244, "Organization", 111, { "hq_city" => [ "Houston", nil, 3117 ], "hq_state" => [ "TX", nil, 3117 ] } ], # ampeers
    [ 3245, "Organization", 99, { "hq_city" => [ "Knoxville", nil, 3057 ], "hq_state" => [ "TN", nil, 3057 ] } ], # analysis-and-measurement-services
    [ 3246, "Organization", 229, { "description" => [ "We design and manufacture modular, transportable reactors for strategic energy applications on Earth and in space.", "Antares develops fission microreactors for strategic energy on Earth, in space and underwater.", 3230 ] } ], # antares-nuclear
    [ 3247, "Organization", 110, { "hq_city" => [ "Larkspur", nil, 3118 ], "hq_state" => [ "CO", nil, 3118 ] } ], # aqwest
    [ 3248, "Organization", 149, { "legal_name" => [ "ASP Isotopes Inc.", nil, 3197 ] } ], # asp-isotopes
    [ 3249, "Organization", 94, { "hq_city" => [ "Naples", nil, 3058 ], "hq_state" => [ "FL", nil, 3058 ] } ], # blue-wave-capital-and-consulting
    [ 3253, "Organization", 53, { "description" => [ "Dalton Utilities is a full-service municipal utility service supplying the City of Dalton with electricity, gas, water, and sewer services.", "Public utility, operating since 1889, providing water, electric, natural gas and wastewater services to the City of Dalton and nearby counties", 3167 ] } ], # dalton-utilities
    [ 3254, "Organization", 97, { "hq_city" => [ "Palo Alto", nil, 3055 ], "hq_state" => [ "CA", nil, 3055 ] } ], # electric-power-research-institute
    [ 3255, "Organization", 105, { "hq_city" => [ "Vienna", nil, 3233 ], "hq_state" => [ "VA", nil, 3225 ], "description" => [ "ENSCO, Inc., and its wholly owned subsidiaries, represent a $190 million international technology enterprise with 700+ employees headquartered in the Washington, D.C., area.", "Engineering company in aerospace, national security, rail and cybersecurity; contracted by DOE to build and test a spent-fuel railcar prototype.", 3237 ] } ], # ensco
    [ 3256, "Organization", 16, { "hq_city" => [ "San Francisco", nil, 3053 ], "hq_state" => [ "CA", nil, 3053 ] } ], # general-matter
    [ 3257, "Organization", 23, { "hq_city" => [ "Idaho Falls", nil, 3080 ] } ], # idaho-national-laboratory
    [ 3258, "Organization", 122, { "description" => [ "A developer of next generation micro modular PWR power plants.", "Developer of small modular nuclear power plants that it builds, owns and runs for customers.", 3211 ] } ], # last-energy
    [ 3259, "Organization", 26, { "description" => [ "Lightspeed has been the first investor and an early backer of some of the most innovative companies in the world.", "Venture capital firm that invests from seed stage through later rounds.", 3071 ] } ], # lightspeed-venture-partners
    [ 3260, "Organization", 55, { "description" => [ "MEAG Power provides reliable, competitively priced, wholesale electric power to 49 Participant public power communities throughout Georgia.", "Wholesale electric power provider to 49 public power communities in Georgia", 3173 ] } ], # meag-power
    [ 3261, "Organization", 109, { "hq_city" => [ "Okemos", nil, 3120 ], "hq_state" => [ "MI", nil, 3120 ] } ], # nusenics
    [ 3262, "Organization", 158, { "description" => [ "Ocean Atomics is an American company designing, licensing, and assembling a standardized nuclear electric power plant and the surrounding support systems for maritime applications.", "American company designing and assembling a standardized nuclear power plant for maritime use, built on water-cooled reactors.", 3208 ] } ], # ocean-atomics
    [ 3263, "Organization", 56, { "description" => [ "We’re a cooperative that operates on a not-for-profit basis, part of the electric cooperative model in Georgia and owned by the 38 EMCs we serve, instead of individual shareholders.", "Georgia electric power producer that generates power for the state's electric membership corporations (EMCs)", 3170 ] } ], # oglethorpe-power
    [ 3264, "Organization", 57, { "description" => [ "Old Dominion Electric Cooperative is a not-for-profit wholesale generation and transmission electric cooperative owned by those we serve.", "Not-for-profit cooperative that buys, makes and moves power for 11 member distribution cooperatives across Virginia, Maryland and Delaware", 3168 ] } ], # old-dominion-electric-cooperative
    [ 3265, "Organization", 167, { "description" => [ "PNNL advances the frontiers of knowledge, taking on some of the world’s greatest science and technology challenges.", "National laboratory for scientific discovery in chemistry, data analytics and Earth science, and for energy resilience and national security.", 3231 ] } ], # pacific-northwest-national-laboratory
    [ 3267, "Organization", 127, { "hq_city" => [ "El Segundo", nil, 3092 ], "hq_state" => [ "CA", nil, 3092 ] } ], # radiant
    [ 3268, "Organization", 128, { "legal_name" => [ "Samsung C&T Corporation", nil, 3199 ] } ], # samsung-c-t
    [ 3269, "Organization", 114, { "hq_city" => [ "Fort Collins", nil, 3115 ], "hq_state" => [ "CO", nil, 3115 ] } ], # xuv-lasers
    [ 4010, "Organization", 99, { "description" => [ "AMS provides test equipment, training, and services to verify the performance of instrumentation and control systems (I&C) of nuclear facilities.", "Nuclear engineering consultancy that tests instrumentation and control systems at nuclear facilities.", 3313 ] } ], # analysis-and-measurement-services
    [ 4011, "Organization", 115, { "description" => [ "Develops high power microwave, millimeter wave and terahertz systems for nuclear fusion, DNP, NMR, and EPR spectroscopy.", "Develops high-power microwave, millimeter-wave and terahertz systems for fusion and spectroscopy.", 3310 ] } ], # bridge12
    [ 4012, "Organization", 93, { "description" => [ "CTP is a small business engineering and manufacturing company headquartered in Lynchburg, VA.", "Lynchburg, Virginia manufacturer of silicon carbide nuclear fuel rod cladding.", 3311 ] } ], # ceramic-tubular-products
    [ 4015, "Organization", 109, { "description" => [ "Nusenics develops fiber-optic sensing technologies for measurement environments where conventional electronic sensors face practical limits.", "Develops fiber-optic sensors for harsh environments, including fusion plasma diagnostics.", 3307 ] } ], # nusenics
    [ 4016, "Organization", 56, { "legal_name" => [ "Oglethorpe Power Corporation", nil, 3343 ] } ], # oglethorpe-power
    [ 4018, "Relationship", 45, { "description" => [ "1 award from the U.S. Department of Energy totaling $1.7 billion (2021): DENE0009054.", "ARDP award (Oct 2020): $80M initial funding to demonstrate Natrium; cost-shared, DOE total up to $3.2B over seven years across both ARDP demos subject to appropriations.", 3408 ] } ], # us-department-of-energy -> terrapower (funds)
    [ 4019, "Relationship", 46, { "description" => [ "4 awards from the U.S. Department of Energy totaling $967.5 million (first in 2016, latest in 2023): DENE0009040, DENE0008472, DENE0008745 and 1 more.", "ARDP award (Oct 2020): $80M initial funding for a four-unit Xe-100 plant and TRISO fuel fabrication facility; cost-shared.", 3409 ] } ], # us-department-of-energy -> x-energy (funds)
    [ 4020, "Relationship", 48, { "description" => [ "1 award from the U.S. Department of Energy totaling $1.5 million (2021): DESC0021623.", "Selected (May 2023) in the $46M Milestone-Based Fusion Development Program; payments only on verified milestones.", 3411 ] } ] # us-department-of-energy -> commonwealth-fusion-systems (funds)
  ].freeze
  KINDS = { "Organization" => :organization, "Relationship" => :relationship }.freeze

  def up
    WRITES.each do |event_id, type, id, fields|
      record = type.constantize.find_by(id:)
      next say("#{type} #{id} is gone; nothing to put back for event #{event_id}") unless record
      next say("#{label(record)} is #{record.verification_status} now; left as it is") unless record.verification_status == "verified"
      next say("Event #{event_id} isn't the seed's write on #{type} #{id} as Data Quality read it; left as it is") unless pinned?(event_id, type, id, fields)

      current = fields.keys.to_h { |field| [ field, record.public_send(field) ] }
      already = fields.select { |field, (approved, _, _)| current[field] == approved }.keys
      restore = fields.select { |field, (approved, seed_value, _)| current[field] == seed_value && current[field] != approved }
      decided = fields.keys - already - restore.keys
      say("#{label(record)}: already holds the approved #{already.join(' and ')}") if already.any?
      say("#{label(record)}: #{decided.join(' and ')} changed again since the seed run; left as it is") if decided.any?
      next if restore.empty?

      approvals = restore.values.map(&:last).uniq.sort
      result = Directory::FactWriter.write(KINDS.fetch(type), restore.transform_values(&:first).merge(id:),
        verification: { status: "verified", by: BY,
          reason: "Restores Tosin's approval (event #{approvals.join(', ')}), undone by the seed (event #{event_id}) before #948's guard (#947); #{reason}",
          context: { "restores_event" => event_id, "approval_events" => approvals } })
      raise "putting back #{type} #{id} failed: #{Array(result.errors).join('; ')}" unless result.ok?

      say "#{label(record)}: put back #{restore.keys.join(' and ')}"
    end
  end

  private
    # The event is the seed's write as Data Quality read it: same record, and each field went from the approved
    # value to the seed's.
    def pinned?(event_id, type, id, fields)
      event = VerificationEvent.find_by(id: event_id) or return false
      return false unless [ event.subject_type, event.subject_id ] == [ type, id ]

      fields.all? { |field, (approved, seed_value, _)| event.changed_values[field] == [ approved, seed_value ] }
    end

    def label(record) = record.respond_to?(:slug) ? "#{record.name} (#{record.class.name} #{record.id})" : "#{record.class.name} #{record.id}"
end
