require "test_helper"
load Rails.root.join("db/data/20261125220000_restore_seed_reverted_approvals.rb")

# #947: the 25 Nov seed run wrote null or older values over 16 that Tosin had approved; this step puts his back.
class RestoreSeedRevertedApprovalsTest < ActiveSupport::TestCase
  BY = "human:tosin"

  def organization(id, name, **values)
    Organization.find_by(id:)&.destroy!
    Organization.create!(id:, name:, slug: name.parameterize, verification_status: "verified", verified_by: BY, **values)
  end

  # The seed's revert event, as read in production.
  def revert_event(event_id, record, changes)
    VerificationEvent.find_by(id: event_id)&.delete
    VerificationEvent.create!(id: event_id, subject: record, from_status: "verified", to_status: "verified", by: BY, changed_values: changes)
  end

  setup do
    @bridge12 = organization(115, "Bridge12")
    revert_event(4254, @bridge12, { "hq_city" => [ "Natick", nil ], "hq_state" => [ "MA", nil ] })
    @fuels = organization(11, "Energy Fuels", hq_city: "Denver", hq_state: "CO")
    revert_event(4259, @fuels, { "hq_city" => [ "Lakewood", "Denver" ] })
    @power = organization(129, "Standard Power")
    revert_event(4266, @power, { "website" => [ "https://standardpower.com", nil ] })
    microsoft = organization(900_001, "Microsoft")
    helion = organization(900_002, "Helion Energy")
    seed_text = RestoreSeedRevertedApprovals::EVENTS[4269][3]["description"].last
    @link = Relationship.create!(id: 36, from_organization: microsoft, to_organization: helion, relationship_type: "offtake_with",
      description: seed_text, verification_status: "verified", verified_by: BY)
    revert_event(4269, @link, { "description" => RestoreSeedRevertedApprovals::EVENTS[4269][3]["description"] })
  end

  def run_it = RestoreSeedRevertedApprovals.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "puts back each approved value, cites the approval and the revert, and a rerun changes nothing" do
    run_it
    assert_equal [ "Natick", "MA" ], @bridge12.reload.attributes.values_at("hq_city", "hq_state")
    assert_equal [ "Lakewood", "CO" ], @fuels.reload.attributes.values_at("hq_city", "hq_state"), "only the city was approved"
    assert_equal "https://standardpower.com", @power.reload.website
    assert_match(/\AAnnounced agreement \(May 2023\)/, @link.reload.description)

    event = VerificationEvent.where(subject: @bridge12).order(:id).last
    assert_equal({ "restores_event" => 4254, "approval_event" => 4216 }, event.context)
    assert_equal BY, event.by
    assert_match "Restores Tosin's approval (event 4216), undone by the seed run of 25 Nov (#947); deploy abc1234, PR #1", event.reason
    assert_equal [ nil, "Natick" ], event.changed_values["hq_city"]

    assert_no_difference "VerificationEvent.count" do
      output = run_it.output
      assert_includes output, "Bridge12 (Organization 115): already holds the approved hq_city and hq_state"
    end
  end

  test "the seed's next run keeps a restored value, even from a file that still says otherwise" do
    run_it
    dir = Dir.mktmpdir
    File.write(File.join(dir, "bridge12.yml"), { "name" => "Bridge12", "website" => "https://www.bridge12.com", "hq" => { "city" => "Boston", "state" => "MA" },
      "status" => "active", "roles" => [], "technologies" => [], "relationships" => [], "facilities" => [] }.to_yaml)
    loader = Seed::OrganizationLoader.new(dir, facilities: File.join(dir, "none.yml")).load!
    assert_equal "Natick", @bridge12.reload.hq_city
    assert_match(/bridge12: kept organization 115's hq_city "Natick"/, loader.kept.join("\n"))
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "a record taken off since is never published again (Copilot, #948)" do
    @power.update_columns(verification_status: "unpublished")
    output = run_it.output
    assert_nil @power.reload.website
    assert_equal "unpublished", @power.verification_status
    assert_includes output, "Standard Power (Organization 129) is unpublished now; left as it is"
  end

  test "a record decided again since the seed run is left as it is and said; an event that isn't the one read is left" do
    @bridge12.update_columns(hq_city: "Boston")
    VerificationEvent.find(4259).delete
    revert_event(4259, @fuels, { "hq_city" => [ "Golden", "Denver" ] })

    output = run_it.output
    assert_equal [ "Boston", "MA" ], @bridge12.reload.attributes.values_at("hq_city", "hq_state"), "the state was still the seed's: put back"
    assert_includes output, "Bridge12 (Organization 115): hq_city changed again since the seed run; left as it is"
    assert_equal "Denver", @fuels.reload.hq_city
    assert_includes output, "Event 4259 isn't the seed's revert of Organization 11 as read on 25 Nov; Organization 11 left as it is"
    assert_includes output, "Organization 165 is gone; nothing to restore for event 4255"
  end
end
