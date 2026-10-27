require_relative "directory_builders"

# The three pages Design drew the connections map for (#363), built like the
# live records: Plant Vogtle (four owners in a bundle), TerraPower (a
# conditional offer that becomes a Note) and Constellation (13 plants that
# fold, four buyers in a bundle).
module ConnectionsFixtures
  include DirectoryBuilders

  def build_vogtle
    utility = role("utility")
    vendor = Role.find_by(key: "reactor_vendor") || role("reactor_vendor")
    @vogtle = cite!(plant("Plant Vogtle", facility_type: "power_reactor", status: "operating", state: "GA", city: "Waynesboro"))
    units = (1..4).map { |n| cite!(plant("Vogtle Unit #{n}", parent: @vogtle, status: "operating", reactor_type: n < 3 ? "PWR" : "AP1000", capacity_mw: 1100)) }
    { "Georgia Power" => 45.7, "Oglethorpe Power Corporation" => 30, "MEAG Power" => 22.7, "Dalton Utilities" => 1.6 }.each do |name, share|
      owner = cite!(company(name, roles: [ utility ]))
      cite!(link(owner, "owns", @vogtle)).update!(ownership_pct: share)
    end
    operator = cite!(company("Southern Nuclear Operating Company", roles: [ utility ]))
    units.each { |unit| cite!(link(operator, "operates", unit)) }
    westinghouse = firm("Westinghouse Electric Company", roles: [ vendor ])
    units.last(2).each { |unit| cite!(link(westinghouse, "vendor_for", unit)) }
    @vogtle
  end

  def build_terrapower
    vendor = Role.find_by(key: "reactor_vendor") || role("reactor_vendor")
    @terrapower = firm("TerraPower", roles: [ vendor ], description: "Reactor developer building its first Natrium plant.")
    doe = cite!(company("U.S. Department of Energy", roles: [ role("government_agency") ]))
    fuel = cite!(company("Global Nuclear Fuel–Americas", roles: [ role("fuel") ]))
    meta = Organization.find_by(name: "Meta") || cite!(company("Meta", roles: [ role("data_center_offtaker") ]))
    deal(doe, "funds", @terrapower, "ARDP award (Oct 2020): cost-shared funding to build the Natrium demonstration plant.")
    deal(fuel, "supplies", @terrapower, "Signed agreement (Oct 2022) to build the Natrium Fuel Facility at Wilmington.")
    deal(meta, "funds", @terrapower, "Development funding (Jan 2026) with rights to energy from up to eight Natrium units.")
    deal(doe, "supplies", @terrapower, "Conditional (Apr 2025): the Department of Energy offered HALEU fuel, subject to conditions.")
    kemmerer = cite!(plant("Kemmerer Unit 1", facility_type: "power_reactor", status: "under_construction", state: "WY"))
    cite!(link(@terrapower, "owns", kemmerer))
    @terrapower
  end

  def build_constellation
    utility = Role.find_by(key: "utility") || role("utility")
    buyer = Role.find_by(key: "data_center_offtaker") || role("data_center_offtaker")
    @constellation = cite!(company("Constellation", roles: [ utility ], description: "The largest operator of US nuclear plants."))
    plants = %w[Braidwood Byron Calvert\ Cliffs Clinton Crane Dresden LaSalle Limerick Nine\ Mile\ Point Peach\ Bottom Quad\ Cities Ginna FitzPatrick]
      .map { |name| cite!(plant("#{name} Clean Energy Center", facility_type: "power_reactor", status: "operating", state: "IL")) }
    plants.each { |site| cite!(link(@constellation, "operates", site)) }
    plants.select { |site| site.name.start_with?("Clinton", "Crane") }.each { |site| cite!(link(@constellation, "owns", site)) }
    %w[Amazon Google Meta Microsoft].each do |name|
      company = Organization.find_by(name:) || cite!(company(name, roles: [ buyer ]))
      deal(company, "offtake_with", @constellation, "Signed 20-year PPA (2024) for nuclear power from a Constellation plant.")
    end
    doe = Organization.find_by(name: "U.S. Department of Energy") || cite!(company("U.S. Department of Energy", roles: [ role("government_agency") ]))
    deal(doe, "funds", @constellation, "Award (2021): civil nuclear credit funding.")
    allied = cite!(company("Allied Power", roles: [ role("reactor_services") ]))
    deal(allied, "supplies", @constellation, "Signed multi-year contract extension (Feb 2023): maintenance at 12 Constellation plants.")
    helion = cite!(company("Helion", roles: [ Role.find_by(key: "reactor_vendor") || role("reactor_vendor") ]))
    deal(@constellation, "supplies", helion, "Announced plan (May 2023): Constellation is to market the power from Helion's first fusion plant.")
    @constellation
  end

  # A company by name: the fixture's own record when there is one (Westinghouse, TerraPower).
  def firm(name, roles: [], **attributes)
    existing = Organization.find_by(name:)
    return cite!(company(name, roles:, **attributes)) unless existing

    existing.update!(**attributes) if attributes.any?
    existing.verify!(by: "human:test") unless existing.verified?
    roles.each { |r| OrganizationRole.create!(organization: existing, role: r, **verification(true)) unless existing.organization_roles.exists?(role: r) }
    cite!(existing.reload)
  end

  def deal(from, type, to, description)
    cite!(link(from, type, to)).tap { |relationship| relationship.update!(description:) }
  end
end
