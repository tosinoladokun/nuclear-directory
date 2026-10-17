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
  [ "waste_decommissioning", "Waste and decommissioning", "Decommissions shut-down plants, or stores, transports or disposes of spent fuel and radioactive waste." ]
].freeze

TECHNOLOGIES = [
  [ "fission", "Fission", "Energy from splitting heavy atoms such as uranium." ],
  [ "fusion", "Fusion", "Energy from fusing light atoms such as hydrogen isotopes." ],
  [ "smr", "Small modular reactor", "Fission reactor of roughly 300 MWe or less, built from factory-made modules.", "fission" ]
].freeze

def seed_lookup(model, rows)
  rows.each do |key, name, description, parent_key|
    record = model.find_or_initialize_by(key: key)
    record.update!(name: name, description: description, parent: parent_key && model.find_by!(key: parent_key))
  end
end

ActiveRecord::Base.transaction do
  seed_lookup(Role, ROLES)
  seed_lookup(Technology, TECHNOLOGIES)
end

loader = Seed::OrganizationLoader.new(Rails.root.join("db/seeds/organizations")).load!
unless Rails.env.test?
  loader.results.each do |kind, counts|
    puts format("%-24s %3d created, %3d updated", kind, counts[:created], counts[:updated])
  end
end

# A local admin account for trying the admin screens (#86). Development only:
# elsewhere the account is made with `bin/rails admin:create`.
if Rails.env.development?
  User.find_or_create_by!(email_address: "admin@example.com") do |user|
    user.handle = "dev"
    user.password = "development-only-password"
  end
end
