# Data the app needs in every environment, safe to re-run:
# 1. Lookup tables (roles, technologies), matched by key and updated in
#    place. To add one, add a line here and run `bin/rails db:seed`.
# 2. The hand-checked organizations in db/seeds/organizations/*.yml, loaded
#    through Directory::FactWriter (see lib/seed/organization_loader.rb).
#
# Parents must be listed before their children.

ROLES = [
  [ "fuel", "Fuel", "Mines, converts, enriches or fabricates nuclear fuel (uranium, HALEU, TRISO)." ],
  [ "mining", "Mining and milling", "Mines uranium (conventional or in-situ recovery) or mills ore into concentrate.", "fuel" ],
  [ "conversion", "Conversion", "Converts uranium concentrate into UF6 for enrichment.", "fuel" ],
  [ "enrichment", "Enrichment", "Enriches uranium, including HALEU.", "fuel" ],
  [ "fabrication", "Fuel fabrication", "Makes finished fuel such as fuel assemblies or TRISO particles.", "fuel" ],
  [ "reactor_vendor", "Reactor vendor", "Designs and sells reactors, from large light-water plants to SMRs and microreactors." ],
  [ "project_developer", "Project developer", "Develops, finances and will own or run new nuclear plants." ],
  [ "components", "Components", "Makes equipment for nuclear or fusion plants: pumps, valves, forgings, magnets, instrumentation and control hardware." ],
  [ "isotopes", "Isotopes", "Produces medical or industrial isotopes." ],
  [ "waste_decommissioning", "Waste and decommissioning", "Stores, transports or disposes of spent fuel and waste, or decommissions plants." ],
  [ "reactor_services", "Reactor services", "Maintains, inspects, refuels or upgrades operating reactors." ],
  [ "utility", "Utility", "Sells electricity to customers and owns or plans nuclear generation." ],
  [ "operator", "Operator", "Holds the license and runs a nuclear facility day to day." ],
  [ "data_center_offtaker", "Data center offtaker", "Data center or hyperscaler that has agreed to buy nuclear power." ],
  [ "coolant", "Coolant", "Supplies or develops reactor coolant; sub-roles name the coolant type." ],
  [ "molten_salt", "Molten salt", "Molten salt coolant (e.g. FLiBe) or molten salt reactors.", "coolant" ],
  [ "water", "Water", "Light water coolant.", "coolant" ],
  [ "helium", "Helium", "Helium gas coolant, as used in high-temperature gas reactors.", "coolant" ],
  [ "sodium", "Sodium", "Liquid sodium coolant, as used in sodium fast reactors.", "coolant" ],
  [ "lead", "Lead", "Liquid lead or lead-bismuth coolant.", "coolant" ],
  [ "heavy_water", "Heavy water", "Heavy water (D2O) coolant or moderator.", "coolant" ],
  [ "regulatory_consultant", "Regulatory consultant", "Helps companies through NRC licensing and other approvals." ],
  [ "venture_capital", "Venture capital", "Invests equity in nuclear companies." ],
  [ "government_agency", "Government agency", "Regulates or funds the industry, e.g. NRC, DOE." ],
  [ "national_lab", "National lab", "National laboratory doing nuclear research or running test reactors." ],
  [ "university", "University", "University doing nuclear research or running a research reactor." ],
  [ "research_organization", "Research organization", "Independent research organization doing nuclear research and development." ]
].freeze

TECHNOLOGIES = [
  [ "fission", "Fission", "Energy from splitting heavy atoms such as uranium." ],
  [ "fusion", "Fusion", "Energy from fusing light atoms such as hydrogen isotopes." ],
  [ "smr", "Small modular reactor", "Fission reactor of roughly 300 MWe or less, built from factory-made modules.", "fission" ]
].freeze

# Returns { created:, changed:, unchanged: } for the table.
def seed_lookup(model, rows)
  counts = { created: 0, changed: 0, unchanged: 0 }
  rows.each do |key, name, description, parent_key|
    record = model.find_or_initialize_by(key: key)
    created = record.new_record?
    record.update!(name: name, description: description, parent: parent_key && model.find_by!(key: parent_key))
    counts[created ? :created : (record.saved_changes.except("updated_at").any? ? :changed : :unchanged)] += 1
  end
  counts
end

counts = {}
ActiveRecord::Base.transaction do
  counts["role"] = seed_lookup(Role, ROLES)
  counts["technology"] = seed_lookup(Technology, TECHNOLOGIES)
end

loader = Seed::OrganizationLoader.new(Rails.root.join("db/seeds/organizations")).load!
counts.merge!(loader.results.transform_keys(&:to_s))
unless Rails.env.test?
  counts.each do |kind, row|
    puts format("%-24s %3d created, %3d changed, %3d unchanged", kind, row[:created], row[:changed], row[:unchanged])
  end
  # For bin/deploy-data (#301), which posts them for Data Quality to check.
  File.write(Rails.root.join("tmp/seed_counts.json"), JSON.pretty_generate(counts))
  puts JSON.generate(counts) if ENV["SEED_COUNTS_JSON"] == "1"
end

# A local admin account for trying the admin screens (#86). Development only:
# elsewhere the account is made with `bin/rails admin:create`.
if Rails.env.development?
  User.find_or_create_by!(email_address: "admin@example.com") do |user|
    user.handle = "dev"
    user.password = "development-only-password"
  end
end
