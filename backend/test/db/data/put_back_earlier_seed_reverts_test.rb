require "test_helper"
load Rails.root.join("db/data/20261126170000_put_back_earlier_seed_reverts.rb")

# #947 follow-up: Data Quality's 50 fields that seed runs before #948's guard wrote over; this step puts back what
# Tosin approved, only while the record still holds the seed's value.
class PutBackEarlierSeedRevertsTest < ActiveSupport::TestCase
  BY = "human:tosin"
  WRITES = PutBackEarlierSeedReverts::WRITES

  def write_for(event_id, id) = WRITES.find { |event, _, record_id, _| event == event_id && record_id == id }

  # The record as the seed left it, and the seed's event, as read in production.
  def as_seed_left(event_id, id, name, **extra)
    _, type, _, fields = write_for(event_id, id)
    VerificationEvent.find_by(id: event_id)&.delete
    record = type.constantize.find_by(id:)
    record&.destroy! if type == "Organization"
    values = fields.transform_values { |(_, seed_value, _)| seed_value }
    record = yield(values) if block_given?
    record ||= Organization.create!(id:, name:, slug: name.parameterize, verification_status: "verified", verified_by: BY, **values, **extra)
    VerificationEvent.create!(id: event_id, subject: record, from_status: "verified", to_status: "verified", by: BY,
      changed_values: fields.transform_values { |(approved, seed_value, _)| [ approved, seed_value ] })
    record
  end

  setup do
    @container = as_seed_left(2994, 96, "Container Technologies Industries")
    @ensco = as_seed_left(3255, 105, "ENSCO")
    @oglethorpe = as_seed_left(4016, 56, "Oglethorpe Power")
    @oglethorpe.update_columns(legal_name: "Oglethorpe Power Corporation") # put back by the 26 Nov seed run
    doe = Organization.create!(id: 900_101, name: "U.S. Department of Energy", slug: "us-doe-test", verification_status: "verified", verified_by: BY)
    terrapower = Organization.create!(id: 900_102, name: "TerraPower", slug: "terrapower-test", verification_status: "verified", verified_by: BY)
    Relationship.find_by(id: 50)&.destroy!
    @haleu = as_seed_left(2841, 50, nil) do |values|
      Relationship.create!(id: 50, from_organization: doe, to_organization: terrapower, relationship_type: "supplies",
        verification_status: "verified", verified_by: BY, **values)
    end
    # Later events get ids above the pinned ones, as in production.
    %w[verification_events organizations relationships].each { |table| ActiveRecord::Base.connection.reset_pk_sequence!(table) }
  end

  def run_it = PutBackEarlierSeedReverts.new(reason: "deploy abc1234, PR #1").tap(&:up)
  def said(migration) = migration.output.join("\n")

  test "puts back each approved value with its approval events, says one already back, and a rerun changes nothing" do
    output = said(run_it)

    assert_equal [ "Helenwood", "TN" ], @container.reload.attributes.values_at("hq_city", "hq_state")
    assert_equal [ "Vienna", "VA" ], @ensco.reload.attributes.values_at("hq_city", "hq_state")
    assert_match(/\AENSCO, Inc\., and its wholly owned subsidiaries/, @ensco.description)
    assert_equal "Conditional HALEU allocation, round 1 (April 9, 2025)", @haleu.reload.description
    assert_includes output, "Oglethorpe Power (Organization 56): already holds the approved legal_name"

    event = VerificationEvent.where(subject: @ensco).order(:id).last
    assert_equal BY, event.by
    assert_equal({ "restores_event" => 3255, "approval_events" => [ 3225, 3233, 3237 ] }, event.context)
    assert_match "undone by the seed (event 3255) before #948's guard (#947); deploy abc1234, PR #1", event.reason

    assert_no_difference "VerificationEvent.count" do
      run_it
    end
  end

  test "the next seed run keeps a put-back value from a file that still says null" do
    run_it
    dir = Dir.mktmpdir
    File.write(File.join(dir, "container.yml"), { "name" => "Container Technologies Industries", "hq" => nil, "status" => "active",
      "roles" => [], "technologies" => [], "relationships" => [], "facilities" => [] }.to_yaml)
    Seed::OrganizationLoader.new(dir, facilities: File.join(dir, "none.yml")).load!
    assert_equal "Helenwood", @container.reload.hq_city
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "a field changed again, a record no longer verified, or an event that isn't the one read is left and said" do
    @container.update_columns(hq_city: "Oneida")
    @ensco.update_columns(verification_status: "unpublished")
    VerificationEvent.find(2841).update_columns(changed_values: { "description" => [ "other", "text" ] })

    output = said(run_it)

    assert_equal [ "Oneida", "TN" ], @container.reload.attributes.values_at("hq_city", "hq_state"), "the state still held the seed's null"
    assert_includes output, "Container Technologies Industries (Organization 96): hq_city changed again since the seed run; left as it is"
    assert_nil @ensco.reload.hq_city
    assert_includes output, "ENSCO (Organization 105) is unpublished now; left as it is"
    assert_not_equal "Conditional HALEU allocation, round 1 (April 9, 2025)", @haleu.reload.description
    assert_includes output, "Event 2841 isn't the seed's write on Relationship 50 as Data Quality read it; left as it is"
  end

  test "the list is Data Quality's 50 fields in 37 seed writes" do
    assert_equal 50, WRITES.sum { |*, fields| fields.size }
    assert_equal 37, WRITES.size
  end
end
