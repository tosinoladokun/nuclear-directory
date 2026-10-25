require "test_helper"

class Seed::OrganizationLoaderTest < ActiveSupport::TestCase
  setup do
    Role.create!(key: "fuel", name: "Fuel")
    Role.create!(key: "enrichment", name: "Enrichment", parent: Role.find_by!(key: "fuel"))
    @dir = Dir.mktmpdir
  end

  teardown do
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@facilities_dir) if @facilities_dir
  end

  # Kept out of @dir, which holds only organization files.
  def facilities_file = File.join(@facilities_dir ||= Dir.mktmpdir, "facilities.yml")

  def write_file(slug, doc)
    File.write(File.join(@dir, "#{slug}.yml"), doc.deep_stringify_keys.to_yaml)
  end

  def org(name, website:, **extra)
    { name: name, aliases: [], website: website, hq: nil, country_code: "US", status: "active",
      roles: [], technologies: [], relationships: [], facilities: [], notes: "" }.merge(extra)
  end

  def item(**extra)
    { source_url: "https://example.com/news", quote: "A quote.", confidence: 0.8, published: "2026-01-02" }.merge(extra)
  end

  test "tags a role and its sub-role, and records the source" do
    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com",
      roles: [ item(key: "fuel", subtype: "enrichment") ]))

    loader = Seed::OrganizationLoader.new(@dir).load!

    acme = Organization.find_by!(slug: "acme-fuel")
    assert_equal %w[enrichment fuel], acme.roles.pluck(:key).sort
    assert_equal({ created: 2, changed: 0, unchanged: 0 }, loader.results[:organization_role])
    assert_equal Date.new(2026, 1, 2), Source.find_by!(url: "https://example.com/news").published_on
  end

  test "a file that states no field leaves it; a null description clears it; a source-only description leaves the text" do
    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com", description: { text: "By hand", source_url: "https://example.com/a", quote: "By hand" }))
    Seed::OrganizationLoader.new(@dir).load!
    acme = Organization.find_by!(slug: "acme-fuel")
    acme.update_columns(hq_city: "Springfield", legal_name: "Acme Fuel, Inc.")

    sparse = { name: "Acme Fuel, Inc.", status: "active", roles: [], technologies: [], relationships: [], facilities: [], notes: "" }
    write_file("acme-fuel", sparse)
    Seed::OrganizationLoader.new(@dir).load!
    assert_equal [ "https://acmefuel.com", "US", "By hand", "Springfield", "Acme Fuel, Inc." ],
      acme.reload.attributes.values_at("website", "country_code", "description", "hq_city", "legal_name")

    write_file("acme-fuel", sparse.merge(description: { source_url: "https://example.com/a", quote: "By hand" }))
    Seed::OrganizationLoader.new(@dir).load!
    assert_equal "By hand", acme.reload.description

    write_file("acme-fuel", sparse.merge(description: nil))
    Seed::OrganizationLoader.new(@dir).load!
    assert_nil acme.reload.description
  end

  test "a re-seed counts what it changed apart from what it only restated (#301)" do
    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com", roles: [ item(key: "fuel") ]))
    Seed::OrganizationLoader.new(@dir).load!

    again = Seed::OrganizationLoader.new(@dir).load!
    assert_equal({ created: 0, changed: 0, unchanged: 1 }, again.results[:organization], "nothing new: unchanged, not updated")
    assert_equal({ created: 0, changed: 0, unchanged: 1 }, again.results[:organization_role])

    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.org", roles: [ item(key: "fuel") ]))
    edited = Seed::OrganizationLoader.new(@dir).load!
    assert_equal 1, edited.results[:organization][:changed]
  end

  test "organizations sharing a website get no matching domain" do
    write_file("parent", org("Parent Co", website: "https://shared.com"))
    write_file("child", org("Child Co", website: "https://www.shared.com/child"))
    write_file("solo", org("Solo Co", website: "https://solo.com"))

    Seed::OrganizationLoader.new(@dir).load!

    assert_equal [ nil, nil ], Organization.where(slug: %w[parent child]).pluck(:domain)
    assert_equal "https://shared.com", Organization.find_by!(slug: "parent").website
    assert_equal "solo.com", Organization.find_by!(slug: "solo").domain
  end

  test "a later facility entry with blank details doesn't erase ones already stored" do
    write_file("a-owner", org("A Owner", website: "https://a-owner.com",
      facilities: [ item(name: "Plant Vogtle", type: "owns", city: "Waynesboro", state: "GA") ]))
    write_file("b-operator", org("B Operator", website: "https://b-operator.com",
      facilities: [ item(name: "Plant Vogtle", type: "operates", city: "", state: "  ") ]))

    Seed::OrganizationLoader.new(@dir).load!

    vogtle = Facility.find_by!(name: "Plant Vogtle")
    assert_equal [ "Waynesboro", "GA" ], [ vogtle.city, vogtle.state ]
    assert_equal 2, vogtle.facility_relationships.count
  end

  # #251: an owns-link listed twice with different sources, the first
  # without a share and the second with it, was rewriting the share on
  # every re-seed (nil, then back) and logging four verification events
  # each time. A missing ownership_pct is "nothing to say", not "clear".
  test "a second entry about the same owns-link that omits the share keeps the one another entry set" do
    write_file("a-owner", org("A Owner", website: "https://a-owner.com",
      facilities: [ item(name: "Plant Vogtle", type: "owns", ownership_pct: 45.7),
                    item(name: "Plant Vogtle", type: "owns", source_url: "https://example.com/other",
                      quote: "A Owner has a stake.") ])) # no ownership_pct

    Seed::OrganizationLoader.new(@dir).load!

    link = Facility.find_by!(name: "Plant Vogtle").facility_relationships.sole
    assert_equal 45.7, link.ownership_pct, "the first entry's share stands"
    first_events = link.verification_events.count

    # A re-seed logs no event, because the second entry doesn't clear the share.
    Seed::OrganizationLoader.new(@dir).load!

    assert_equal first_events, link.verification_events.count, "a re-seed logs nothing when nothing changed"
    assert_equal 45.7, link.reload.ownership_pct
  end

  test "loads brand names, descriptions, an HQ in two entries, and ownership stakes" do
    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com",
      legal_name: "Acme Fuel, Inc.",
      description: { "text" => "Makes fuel.", "source_url" => "https://example.com/about", "quote" => "Acme Fuel, Inc. makes fuel." },
      hq: [ { "state" => "TN" }, item(city: "Oak Ridge", source_url: "https://example.com/hq", quote: "Based in Oak Ridge.") ],
      facilities: [ item(name: "Acme Plant", type: "owns", ownership_pct: 40.0) ]))

    Seed::OrganizationLoader.new(@dir).load!

    acme = Organization.find_by!(slug: "acme-fuel")
    assert_equal [ "Acme Fuel, Inc.", "Makes fuel.", "Oak Ridge", "TN" ], [ acme.legal_name, acme.description, acme.hq_city, acme.hq_state ]
    assert_equal 2, acme.evidence.count, "the description and the sourced HQ entry"
    assert_equal 40, acme.facility_relationships.sole.ownership_pct
  end

  test "each record quote says which fields it backs (#398)" do
    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com",
      legal_name: "Acme Fuel, Inc.",
      description: { "text" => "Makes fuel.", "source_url" => "https://example.com/about", "quote" => "Acme Fuel, Inc. makes fuel." },
      hq: [ { "state" => "TN" }, item(city: "Oak Ridge", source_url: "https://example.com/hq", quote: "Based in Oak Ridge.") ]))

    Seed::OrganizationLoader.new(@dir).load!
    Seed::OrganizationLoader.new(@dir).load!

    fields = Organization.find_by!(slug: "acme-fuel").evidence.to_h { |row| [ row.quote, row.fields ] }
    assert_equal({ "Acme Fuel, Inc. makes fuel." => %w[description legal_name], "Based in Oak Ridge." => %w[hq_city] }, fields,
      "the description's quote also states the legal name; the HQ entry gives only the city; a re-seed changes nothing")
  end

  test "a legal name is cited by the quote that states it" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", legal_name: "Acme Fuel, Inc.",
      roles: [ item(key: "fuel", source_url: "https://example.com/role", quote: "Acme Fuel, Inc. supplies fuel.") ]))

    Seed::OrganizationLoader.new(@dir).load!

    acme = Organization.find_by!(slug: "acme-fuel")
    assert_equal "Acme Fuel, Inc.", acme.legal_name
    assert_equal [ "Acme Fuel, Inc. supplies fuel." ], acme.evidence.map(&:quote)
  end

  test "a legal name no quote states is left blank" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", legal_name: "Acme Fuel Holdings, Inc.",
      aliases: [ "Acme", "Acme Fuel Holdings, Inc." ],
      description: { "text" => "Makes fuel.", "source_url" => "https://example.com/about", "quote" => "We make fuel." }))

    Seed::OrganizationLoader.new(@dir).load!

    acme = Organization.find_by!(slug: "acme-fuel")
    assert_nil acme.legal_name
    assert_equal [ "Acme" ], acme.aliases.map(&:alias) - [ "Acme Fuel" ], "nor is it an alias"
  end

  test "a description's other quotes back the rest of its text" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com",
      description: { "text" => "Makes fuel and vanadium.", "source_url" => "https://example.com/about", "quote" => "We make fuel.",
        "also" => [ { "quote" => "We also make vanadium." },
          { "quote" => "Acme's vanadium plant opened.", "source_url" => "https://example.com/news" } ] }))

    Seed::OrganizationLoader.new(@dir).load!

    evidence = Organization.find_by!(slug: "acme-fuel").evidence.includes(:source)
    assert_equal [ [ "We make fuel.", "https://example.com/about" ], [ "We also make vanadium.", "https://example.com/about" ],
      [ "Acme's vanadium plant opened.", "https://example.com/news" ] ].sort, evidence.map { |e| [ e.quote, e.source.url ] }.sort
  end

  test "facilities.yml details are written field by field, each with its own quote" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [ {
      "name" => "Acme Plant",
      "status" => { "value" => "operating", "source_url" => "https://example.com/status", "quote" => "Running since 2020." },
      "city" => { "value" => nil, "source_url" => "https://example.com/where", "quote" => "Near Sometown." }
    } ] }.to_yaml)

    Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!

    plant = Facility.find_by!(name: "Acme Plant")
    assert plant.operating?
    assert_nil plant.city, "a blank value isn't written"
    assert_includes plant.evidence.pluck(:quote), "Running since 2020."
  end

  test "a plant written field by field counts once: created, then unchanged, then changed (#301)" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    details = ->(status) do
      File.write(facilities_file, { "facilities" => [ {
        "name" => "Acme Plant",
        "status" => { "value" => status, "source_url" => "https://example.com/status", "quote" => "It is #{status}." },
        "state" => { "value" => "GA", "source_url" => "https://example.com/where", "quote" => "In Georgia." }
      } ] }.to_yaml)
    end
    load = -> { Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!.results[:facility] }

    details.("operating")
    assert_equal({ created: 1, changed: 0, unchanged: 0 }, load.call)
    assert_equal({ created: 0, changed: 0, unchanged: 1 }, load.call, "restated: one unchanged row, not one per field")
    details.("planned")
    assert_equal({ created: 0, changed: 1, unchanged: 0 }, load.call, "edited: changed, not also unchanged")
  end

  test "a quote cited twice with different confidences takes the higher, so a re-seed changes nothing (#326)" do
    quote = { "source_url" => "https://example.com/plant", "quote" => "Acme Plant is a fusion plant." }
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com",
      facilities: [ item(name: "Acme Plant", type: "owns").merge(quote, "confidence" => 0.8) ]))
    File.write(facilities_file, { "facilities" => [ {
      "name" => "Acme Plant", "facility_type" => quote.merge("value" => "fusion_facility", "confidence" => 1.0)
    } ] }.to_yaml)
    load = -> { Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!.results[:facility] }

    load.call
    plant = Facility.find_by!(name: "Acme Plant")
    assert_equal [ 1.0 ], plant.evidence.where(quote: quote["quote"]).pluck(:confidence).map(&:to_f)
    assert_equal({ created: 0, changed: 0, unchanged: 1 }, load.call, "nothing moves on a re-seed")
  end

  test "a bad confidence still fails the load, even beside a good one for the same quote (#353)" do
    quote = { "source_url" => "https://example.com/plant", "quote" => "Acme Plant is a fusion plant." }
    [ -0.2, "unknown", 1.5 ].each do |bad|
      write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com",
        facilities: [ item(name: "Acme Plant", type: "owns").merge(quote, "confidence" => bad) ]))
      File.write(facilities_file, { "facilities" => [ {
        "name" => "Acme Plant", "facility_type" => quote.merge("value" => "fusion_facility", "confidence" => 0.8)
      } ] }.to_yaml)

      error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load! }
      assert_match "confidence #{bad.inspect} isn't a number from 0 to 1", error.message
      assert_nil Facility.find_by(name: "Acme Plant"), "nothing was written"
    end
  end

  test "terms added under a pending plant link approved since are verified with it, though the YAML still says pending" do
    entry = item(name: "Acme Plant", type: "offtakes_from", pending: true, pending_reason: "quote doesn't say it")
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ entry ]))
    Seed::OrganizationLoader.new(@dir).load!
    link = FacilityRelationship.sole

    travel 1.hour do
      link.verify!(by: "human:tosin")
      terms = [ { key: "acme-plant-ppa", agreement: "ppa", status: "signed", capacity_mw: 100 } ]
      write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ entry.merge(terms:) ]))
      Seed::OrganizationLoader.new(@dir).load!
    end

    assert DealTerm.find_by!(external_id: "acme-plant-ppa").verified?
    assert_equal [ "acme-plant-ppa" ], Directory::DealList.offtakes.map(&:key)
  end

  test "a plant link marked pending is created pending, and a rerun keeps a later decision" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com",
      facilities: [ item(name: "Acme Plant", type: "owns", pending: true, pending_reason: "quote doesn't say owns") ]))

    Seed::OrganizationLoader.new(@dir).load!
    link = FacilityRelationship.sole
    assert link.pending?
    assert_equal 1, link.evidence.count
    assert Facility.find_by!(name: "Acme Plant").verified?, "only the link waits, not the plant"

    # Tosin approves it in the admin later on.
    travel 1.hour do
      link.verify!(by: "human:tosin")
      Seed::OrganizationLoader.new(@dir).load!
    end
    assert link.reload.verified?

    link.reject!(by: "human:tosin")
    assert_nothing_raised { Seed::OrganizationLoader.new(@dir).load! }
    assert link.reload.rejected?, "a rejection made in the admin survives a rerun"
  end

  test "a plant an earlier seed loaded under a former name is renamed, not created again" do
    old = Facility.create!(name: "Acme Plant (Oak Ridge, TN)")
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [ { "name" => "Acme Plant", "other_names" => [ "Acme Plant (Oak Ridge, TN)" ] } ] }.to_yaml)

    Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!

    assert_equal [ old.id ], Facility.where("name LIKE ?", "Acme Plant%").pluck(:id)
    assert_equal [ "Acme Plant", "acme-plant" ], [ old.reload.name, old.slug ], "the slug a fresh seed would give it"
    assert_equal 1, old.facility_relationships.count
    assert_equal [ "Acme Plant (Oak Ridge, TN)" ], old.aliases.pluck(:alias), "the former name is now an alias"
    assert_equal old.id, Directory::Lookup.facility(name: "Acme Plant (Oak Ridge, TN)").id
  end

  test "a plant's EIA plant ID is loaded, so EIA's crawl finds the seed site (#229)" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [ { "name" => "Acme Plant", "eia_plant_id" => "649" } ] }.to_yaml)

    Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!

    plant = Facility.find_by!(name: "Acme Plant")
    assert_equal "649", plant.eia_plant_id
    assert_equal plant.id, Directory::Lookup.facility(eia_plant_id: "649").id
    assert_empty Seed::OrganizationLoader.new(@dir, facilities: facilities_file).collisions
  end

  test "the dry run reports an EIA plant ID a duplicate site still holds" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [ { "name" => "Acme Plant", "eia_plant_id" => "649" } ] }.to_yaml)
    Facility.create!(name: "Acme", eia_plant_id: "649")

    assert_equal [ "facilities.yml: \"Acme Plant\"'s EIA plant ID 649 already belongs to Acme (acme); merge it in first" ],
      Seed::OrganizationLoader.new(@dir, facilities: facilities_file).collisions.map { |line| line.sub(/: bin.*/, "") }
  end

  test "the dry run compares the site the loader writes to, not names: a same-named other site still collides" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [ { "name" => "Acme Plant", "eia_plant_id" => "649" } ] }.to_yaml)
    Facility.create!(name: "Acme Plant")
    Facility.create!(name: "Acme Plant", eia_plant_id: "649") # a later, same-named site the loader won't write to

    assert_equal 1, Seed::OrganizationLoader.new(@dir, facilities: facilities_file).collisions.size
  end

  test "a site still under a former name that holds the plant ID is the loader's own target, not a collision" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [
      { "name" => "Acme Plant", "other_names" => [ "Acme Plant (Oak Ridge, TN)" ], "eia_plant_id" => "649" } ] }.to_yaml)
    Facility.create!(name: "Acme Plant (Oak Ridge, TN)", eia_plant_id: "649")

    assert_empty Seed::OrganizationLoader.new(@dir, facilities: facilities_file).collisions
  end

  test "the collision message names the site to merge into" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [ { "name" => "Acme Plant", "eia_plant_id" => "649" } ] }.to_yaml)
    kept = Facility.create!(name: "Acme Plant")
    duplicate = Facility.create!(name: "Acme", eia_plant_id: "649")

    assert_match "directory:merge_facility[#{duplicate.id},#{kept.id}]", Seed::OrganizationLoader.new(@dir, facilities: facilities_file).collisions.sole
  end

  test "a former name that was an unquoted legal name is dropped from the aliases on a rerun" do
    Directory::FactWriter.write(:organization, { name: "Acme Fuel Holdings, Inc.", slug: "acme-fuel" })
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com", legal_name: "Acme Fuel Holdings, Inc.",
      aliases: [ "Acme", "Acme Fuel Holdings, Inc." ]))

    Seed::OrganizationLoader.new(@dir).load!

    acme = Organization.find_by!(slug: "acme-fuel")
    assert_equal "Acme Fuel", acme.name, "found under its former name and renamed"
    assert_equal [ "Acme", "Acme Fuel" ], acme.aliases.pluck(:alias).sort
    assert_equal [ [ "Acme Fuel Holdings, Inc." ], [ "Acme", "Acme Fuel" ] ],
      acme.verification_events.order(:id).last.changed_values["aliases"]
  end

  test "a facilities.yml plant already in the database must still be in an organization file" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com"))
    Facility.create!(name: "Nowhere Plant")
    File.write(facilities_file, { "facilities" => [ { "name" => "Nowhere Plant" } ] }.to_yaml)

    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load! }
    assert_match "Nowhere Plant", error.message
  end

  test "an organization an earlier seed loaded on its own is merged in, not collided with" do
    # The earlier seed: Acme USA as its own company, with an alias and a plant.
    write_file("acme", org("Acme", website: "https://acme.com"))
    write_file("acme-usa", org("Acme USA", website: "https://acme.com/usa", aliases: [ "AUSA" ],
      facilities: [ item(name: "Acme Plant", type: "operates") ]))
    Seed::OrganizationLoader.new(@dir).load!
    old = Organization.find_by!(slug: "acme-usa")

    # The new seed: Acme USA is part of Acme.
    File.delete(File.join(@dir, "acme-usa.yml"))
    write_file("acme", org("Acme", website: "https://acme.com", merges: [ "Acme USA" ], aliases: [ "Acme USA", "AUSA" ],
      facilities: [ item(name: "Acme Plant", type: "operates") ]))
    assert_empty Seed::OrganizationLoader.new(@dir).collisions, "a merged name isn't a collision"
    merged = Seed::OrganizationLoader.new(@dir).load!
    assert_equal({ created: 0, changed: 2, unchanged: 0 }, merged.results[:organization], "both companies changed (#301)")
    assert_equal({ created: 0, changed: 1, unchanged: 0 }, merged.results[:facility_relationship], "the moved link changed, though restated")

    acme = Organization.find_by!(slug: "acme")
    assert old.reload.unpublished?
    assert_match "Merged into Acme", old.verification_events.order(:id).last.reason
    assert_equal "human:tosin", old.verified_by
    assert_equal acme.id, Directory::Lookup.organization(name: "Acme USA").id
    assert_equal [ "Acme Plant" ], acme.facility_relationships.map { |link| link.facility.name }
    assert_empty old.aliases

    again = Seed::OrganizationLoader.new(@dir).load!
    assert_equal 1, Organization.where(slug: "acme").count, "a second run has nothing to merge"
    assert_equal({ created: 0, changed: 0, unchanged: 1 }, again.results[:organization])
    assert_equal({ created: 0, changed: 0, unchanged: 1 }, again.results[:facility_relationship])
  end

  test "a merge counts the links it moved, not one that stays as it was decided (#301)" do
    write_file("acme", org("Acme", website: "https://acme.com"))
    write_file("acme-usa", org("Acme USA", website: "https://acme.com/usa",
      facilities: [ item(name: "Acme Plant", type: "operates"), item(name: "Other Plant", type: "owns") ]))
    Seed::OrganizationLoader.new(@dir).load!
    old = Organization.find_by!(slug: "acme-usa")
    old.facility_relationships.joins(:facility).find_by!(facilities: { name: "Other Plant" }).unpublish!(by: "human:tosin", reason: "Sold")

    File.delete(File.join(@dir, "acme-usa.yml"))
    write_file("acme", org("Acme", website: "https://acme.com", merges: [ "Acme USA" ], aliases: [ "Acme USA" ]))
    merged = Seed::OrganizationLoader.new(@dir).load!

    assert_equal({ created: 0, changed: 1, unchanged: 0 }, merged.results[:facility_relationship], "the taken-off link isn't counted")
  end

  test "the dry run lists a name another organization already has" do
    write_file("acme", org("Acme", website: "https://acme.com"))
    write_file("acme-usa", org("Acme USA", website: "https://acme.com/usa"))
    Seed::OrganizationLoader.new(@dir).load!
    File.delete(File.join(@dir, "acme-usa.yml"))
    write_file("acme", org("Acme", website: "https://acme.com", aliases: [ "Acme USA" ]))

    assert_equal [ "acme: \"Acme USA\" already belongs to Acme USA (acme-usa)" ], Seed::OrganizationLoader.new(@dir).collisions
    assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
  end

  test "the dry run ignores a website several files share, as the load does" do
    Organization.create!(name: "Acme Holdings", slug: "acme-holdings", domain: "acme.com")
    write_file("acme", org("Acme", website: "https://acme.com"))
    write_file("acme-fuel", org("Acme Fuel", website: "https://acme.com"))

    assert_empty Seed::OrganizationLoader.new(@dir).collisions
  end

  test "a link an earlier seed published goes back to pending once when marked pending" do
    write_file("acme", org("Acme", website: "https://acme.com", facilities: [ item(name: "Acme Plant", type: "owns") ]))
    Seed::OrganizationLoader.new(@dir).load!
    link = FacilityRelationship.sole
    assert link.verified?

    write_file("acme", org("Acme", website: "https://acme.com",
      facilities: [ item(name: "Acme Plant", type: "owns", pending: true, pending_reason: "Needs a quote that Acme owns it.") ]))
    Seed::OrganizationLoader.new(@dir).load!
    assert link.reload.pending?
    assert_equal [ "human:tosin", "Needs a quote that Acme owns it." ], link.verification_events.order(:id).last.slice(:by, :reason).values

    travel 1.hour do
      link.verify!(by: "human:tosin", reason: "Direct quote found")
      Seed::OrganizationLoader.new(@dir).load!
    end
    assert link.reload.verified?, "a human's later decision isn't undone by a rerun"
  end

  test "a facilities.yml plant must be in an organization file" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com"))
    File.write(facilities_file, { "facilities" => [ { "name" => "Nowhere Plant" } ] }.to_yaml)

    error = assert_raises(Seed::OrganizationLoader::Error) do
      Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!
    end
    assert_match "Nowhere Plant", error.message
  end

  test "a plant whose organization-file write failed is reported, not crashed on, by its details" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com",
      facilities: [ item(name: "Acme Plant", type: "owns", facility_type: "not_a_type") ]))
    File.write(facilities_file, { "facilities" => [ { "name" => "Acme Plant",
      "city" => { "value" => "Oak Ridge", "source_url" => "https://example.com/news", "quote" => "In Oak Ridge." } } ] }.to_yaml)

    error = assert_raises(Seed::OrganizationLoader::Error) do
      Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!
    end
    assert_match "Acme Plant", error.message
  end

  test "a seed file citing a non-web URL fails the load and names it" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com",
      roles: [ item(key: "fuel", source_url: "javascript:alert(1)") ]))

    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
    assert_match 'source "javascript:alert(1)": Url must be an absolute http or https address', error.message
    assert_nil Organization.find_by(slug: "acme-fuel"), "nothing is written"
  end

  test "fails as a whole when any fact can't be written" do
    write_file("acme-fuel", org("Acme Fuel", website: "https://acmefuel.com",
      relationships: [ item(type: "supplies", to: "Nobody At All", description: "x") ]))

    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
    assert_match "unknown organization \"Nobody At All\"", error.message
    assert_nil Organization.find_by(slug: "acme-fuel"), "nothing is written"
    assert_equal 0, Source.where(url: "https://example.com/news").count
  end

  # A licensing stage (#379): the NRC stage a project has reached, with its
  # docket and date, from an NRC record.
  def licensing(**extra)
    { stage: "construction_permit", nrc_docket: "50-7513", effective_on: Date.new(2023, 12, 14),
      facility: "Hermes 1", source_url: "https://www.nrc.gov/reactors/operating/list-power-reactor-units.html",
      quote: "NRC issued a construction permit to Hermes 1." }.merge(extra)
  end

  test "a licensing stage is written on the unit that holds the docket, with its evidence" do
    write_file("acme", org("Acme", website: "https://acme.com",
      facilities: [ item(name: "Hermes 1", type: "owns") ], licensing: [ licensing ]))

    Seed::OrganizationLoader.new(@dir).load!

    stage = LicensingStage.sole
    assert_equal [ "construction_permit", "05007513", Date.new(2023, 12, 14) ],
      [ stage.stage, stage.nrc_docket, stage.effective_on ]
    assert_equal "Hermes 1", stage.facility.name
    assert_equal "human:tosin", stage.verified_by
    assert_equal "NRC issued a construction permit to Hermes 1.", stage.evidence.sole.quote
  end

  test "a design approval is written on the developer, with its design" do
    write_file("acme", org("Acme", website: "https://acme.com",
      licensing: [ licensing(stage: "design_approval", design_name: "US460", facility: nil) ]))

    Seed::OrganizationLoader.new(@dir).load!

    stage = LicensingStage.sole
    assert_equal [ "design_approval", "US460" ], [ stage.stage, stage.design_name ]
    assert_equal "Acme", stage.organization.name
  end

  test "a licensing stage finds its unit by docket before name" do
    Facility.create!(name: "Hermes 1", verification_status: "verified", verified_by: "human:tosin") # an older record of that name
    unit = Facility.create!(name: "Hermes Unit 1", nrc_docket: "05007513", verification_status: "verified", verified_by: "human:tosin")
    write_file("acme", org("Acme", website: "https://acme.com", licensing: [ licensing ]))

    Seed::OrganizationLoader.new(@dir).load!

    assert_equal unit, LicensingStage.sole.facility
  end

  test "a pending licensing entry is refused: nobody could review it in the admin yet" do
    lead = licensing(pending: true, source_url: "https://world-nuclear-news.org/articles/permit", quote: "A permit.")
    write_file("acme", org("Acme", website: "https://acme.com", facilities: [ item(name: "Hermes 1", type: "owns") ], licensing: [ lead ]))

    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
    assert_match "pending: isn't supported for licensing stages", error.message
    assert_equal 0, LicensingStage.count
  end

  test "seed:check reads a stored notice's title, as FactWriter does" do
    url = "https://public-inspection.federalregister.gov/2026-10073.pdf"
    Source.create!(url:, source_kind: "web_page", title: "Long Mott Energy, LLC; Nuclear Regulatory Commission notice")
    write_file("acme", org("Acme", website: "https://acme.com", facilities: [ item(name: "Hermes 1", type: "owns") ],
      licensing: [ licensing(source_url: url, quote: "The application was docketed.") ]))

    assert_empty Seed::OrganizationLoader.new(@dir).licensing_source_problems
  end

  test "a licensing stage found by name on a unit with another docket fails the load" do
    Facility.create!(name: "Hermes 1", nrc_docket: "05007513", verification_status: "verified", verified_by: "human:tosin")
    write_file("acme", org("Acme", website: "https://acme.com", licensing: [ licensing(nrc_docket: "50-7514") ]))

    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
    assert_match "Hermes 1 has docket 05007513, not 05007514", error.message
    assert_equal 0, LicensingStage.count
  end

  test "a licensing stage can name a plant a later file defines" do
    write_file("a-developer", org("A Developer", website: "https://developer.com", licensing: [ licensing ]))
    write_file("z-owner", org("Z Owner", website: "https://owner.com", facilities: [ item(name: "Hermes 1", type: "owns") ]))

    Seed::OrganizationLoader.new(@dir).load!

    assert_equal "Hermes 1", LicensingStage.sole.facility.name
  end

  test "a licensing stage for a plant the seed doesn't have fails the load and names it" do
    write_file("acme", org("Acme", website: "https://acme.com", licensing: [ licensing ]))

    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
    assert_match 'unknown facility "Hermes 1"', error.message
  end

  test "seed:check lists a licensing stage that isn't cited to an NRC record" do
    write_file("acme", org("Acme", website: "https://acme.com",
      facilities: [ item(name: "Hermes 1", type: "owns") ],
      licensing: [ licensing(source_url: "https://world-nuclear-news.org/articles/permit", quote: "A permit.") ]))

    problems = Seed::OrganizationLoader.new(@dir).licensing_source_problems

    assert_equal [ 'acme.yml: licensing "construction_permit" for facility "Hermes 1", docket 50-7513, ' \
      'isn\'t cited to an NRC record: "https://world-nuclear-news.org/articles/permit"' ], problems
  end

  test "seed:check names a design approval by its design" do
    write_file("acme", org("Acme", website: "https://acme.com",
      licensing: [ licensing(stage: "design_approval", design_name: "US460", facility: nil, nrc_docket: "52-048",
        source_url: "https://example.com/news") ]))

    assert_match 'acme.yml: licensing "design_approval" for design "US460", docket 52-048',
      Seed::OrganizationLoader.new(@dir).licensing_source_problems.sole
  end

  test "seed:check is quiet when every licensing stage is cited to an NRC record" do
    write_file("acme", org("Acme", website: "https://acme.com",
      facilities: [ item(name: "Hermes 1", type: "owns") ], licensing: [ licensing ]))

    assert_empty Seed::OrganizationLoader.new(@dir).licensing_source_problems
  end

  test "a unit given with its site loads under that site: one public plant, both units under it, on a fresh load and a re-seed" do
    write_file("holtec", org("Holtec International", website: "https://holtec.com", facilities: [
      item(name: "Indian Point 2", site: "Indian Point", type: "owns"), item(name: "Indian Point 3", site: "Indian Point", type: "owns") ]))
    write_file("hdi", org("Holtec Decommissioning International", website: "https://hdi.example.com", facilities: [
      item(name: "Indian Point 2", site: "Indian Point", type: "operates") ]))

    Seed::OrganizationLoader.new(@dir).load!

    site = Facility.find_by!(name: "Indian Point", parent_id: nil)
    units = Facility.where(name: [ "Indian Point 2", "Indian Point 3" ])
    assert_equal [ site.id ], units.pluck(:parent_id).uniq
    assert_equal 2, units.count, "one unit per name, shared by both companies"
    assert_equal [ "Indian Point" ], DirectoryListing.new(q: "Indian Point").plants.map(&:name)
    assert_equal 3, FacilityRelationship.where(facility: units).count

    Seed::OrganizationLoader.new(@dir).load!
    assert_equal 3, Facility.where("name LIKE 'Indian Point%'").count, "a re-seed makes nothing new"
  end

  test "a same-name plant without a site is taken in as the unit; one under another site fails the load" do
    stray = Facility.create!(name: "Duane Arnold 1")
    write_file("nextera", org("NextEra Energy", website: "https://nextera.example.com", facilities: [
      item(name: "Duane Arnold 1", site: "Duane Arnold Energy Center", type: "operates") ]))
    Seed::OrganizationLoader.new(@dir).load!
    assert_equal Facility.find_by!(name: "Duane Arnold Energy Center").id, stray.reload.parent_id

    other = Facility.create!(name: "Elsewhere")
    Facility.create!(name: "San Onofre 1", parent: other)
    write_file("sce", org("Southern California Edison", website: "https://sce.example.com", facilities: [
      item(name: "San Onofre 1", site: "San Onofre", type: "operates") ]))
    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
    assert_match "already a unit of another site (Elsewhere), not San Onofre", error.message
  end

  test "a unit may share its site's name; an alias under another site isn't moved; re-casing never renames" do
    write_file("ameren", org("Ameren", website: "https://ameren.example.com", facilities: [ item(name: "Callaway", site: "Callaway", type: "operates") ]))
    Seed::OrganizationLoader.new(@dir).load!
    site = Facility.find_by!(name: "Callaway", parent_id: nil)
    assert_equal [ site.id ], Facility.where(name: "Callaway").where.not(id: site.id).pluck(:parent_id)

    write_file("ameren", org("Ameren", website: "https://ameren.example.com", facilities: [ item(name: "CALLAWAY", site: "Callaway", type: "operates") ]))
    Seed::OrganizationLoader.new(@dir).load!
    assert_equal 2, Facility.where("LOWER(name) = 'callaway'").count
    assert_not Facility.exists?(name: "CALLAWAY"), "re-casing the entry doesn't rename the unit"

    other = Facility.create!(name: "Elsewhere")
    Facility.create!(name: "Elsewhere 2", parent: other).aliases.create!(alias: "SONGS 2")
    write_file("sce", org("Southern California Edison", website: "https://sce.example.com", facilities: [ item(name: "SONGS 2", site: "San Onofre", type: "operates") ]))
    error = assert_raises(Seed::OrganizationLoader::Error) { Seed::OrganizationLoader.new(@dir).load! }
    assert_match "already a unit of another site (Elsewhere), not San Onofre", error.message
  end

  test "a site named only through site: can take its details from facilities.yml" do
    write_file("holtec", org("Holtec International", website: "https://holtec.com", facilities: [ item(name: "Indian Point 2", site: "Indian Point", type: "owns") ]))
    File.write(facilities_file, { "facilities" => [ {
      "name" => "Indian Point", "state" => { "value" => "NY", "source_url" => "https://example.com/where", "quote" => "Indian Point is in New York." }
    } ] }.to_yaml)
    Seed::OrganizationLoader.new(@dir, facilities: facilities_file).load!
    assert_equal "NY", Facility.find_by!(name: "Indian Point", parent_id: nil).state
  end

  test "an older same-name NRC unit never takes its site's details; a loose unit is taken in by its alias; new sites and units count as created" do
    Facility.create!(name: "Callaway", nrc_docket: "05000483")
    write_file("ameren", org("Ameren", website: "https://ameren.example.com", facilities: [ item(name: "Callaway 1", site: "Callaway", type: "operates") ]))
    File.write(facilities_file, { "facilities" => [ {
      "name" => "Callaway", "state" => { "value" => "MO", "source_url" => "https://example.com/where", "quote" => "Callaway is in Missouri." }
    } ] }.to_yaml)
    loader = Seed::OrganizationLoader.new(@dir, facilities: facilities_file)
    loader.load!
    site = Facility.find_by!(name: "Callaway", nrc_docket: nil)
    assert_equal "MO", site.state
    assert_nil Facility.find_by!(nrc_docket: "05000483").state, "the docketed record isn't the site"
    created = loader.results.dig(:facility, :created) || loader.results.dig("facility", "created")
    assert created.to_i >= 2, "the new site and unit count as created: #{loader.results.inspect}"

    loose = Facility.create!(name: "San Onofre 2")
    loose.aliases.create!(alias: "SONGS 2")
    write_file("sce", org("Southern California Edison", website: "https://sce.example.com", facilities: [ item(name: "SONGS 2", site: "San Onofre", type: "operates") ]))
    Seed::OrganizationLoader.new(@dir).load!
    assert_equal Facility.find_by!(name: "San Onofre").id, loose.reload.parent_id, "taken in by its alias, keeping its name"
    assert_not Facility.exists?(name: "SONGS 2")
  end

  test "a site under a former name is found beside a same-name NRC unit, in the preflight and the rename" do
    Facility.create!(name: "Callaway", nrc_docket: "05000483")
    old = Facility.create!(name: "Callaway Energy Center", eia_plant_id: "6153")
    write_file("ameren", org("Ameren", website: "https://ameren.example.com", facilities: [ item(name: "Callaway 1", site: "Callaway", type: "operates") ]))
    File.write(facilities_file, { "facilities" => [ { "name" => "Callaway", "other_names" => [ "Callaway Energy Center" ], "eia_plant_id" => "6153" } ] }.to_yaml)
    loader = Seed::OrganizationLoader.new(@dir, facilities: facilities_file)
    assert_empty loader.plant_id_collisions, "the former-name site is the target, not the NRC unit"
    loader.load!
    assert_equal "Callaway", old.reload.name, "renamed in place"
    assert_equal 1, Facility.where(name: "Callaway", nrc_docket: nil, parent_id: nil).count, "no duplicate site"
    assert_equal old.id, Facility.find_by!(name: "Callaway 1").parent_id
  end

  test "a short description loads with its source; a file without one leaves it; a second load changes nothing; over 40 is refused" do
    short = { text: "Uranium enrichment, including HALEU", source_url: "https://example.com/enrich", quote: "We enrich uranium, including HALEU." }
    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com", short_description: short))
    Seed::OrganizationLoader.new(@dir).load!
    acme = Organization.find_by!(slug: "acme-fuel")
    assert_equal "Uranium enrichment, including HALEU", acme.short_description
    assert Evidence.exists?(subject: acme, quote: "We enrich uranium, including HALEU.")

    again = Seed::OrganizationLoader.new(@dir).load!
    assert_equal 0, again.results[:organization][:changed], "the same text again is a restatement"

    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com"))
    Seed::OrganizationLoader.new(@dir).load!
    assert_equal "Uranium enrichment, including HALEU", acme.reload.short_description, "not stated: left as it is"

    write_file("acme-fuel", org("Acme Fuel, Inc.", website: "https://acmefuel.com", short_description: short.merge(text: "x" * 41)))
    assert_raises(StandardError) { Seed::OrganizationLoader.new(@dir).load! }
    assert_equal "Uranium enrichment, including HALEU", acme.reload.short_description
  end
end
