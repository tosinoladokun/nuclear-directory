require "test_helper"

# The one-time repair of the 16 Oct approve-all (#302): pinned values only,
# all or nothing, as human:tosin, once.
class DataQuality::Repairs::ApproveAll20261016Test < ActiveSupport::TestCase
  Repair = DataQuality::Repairs::ApproveAll20261016
  VERIFIED = { verification_status: "verified", verified_by: "agent:approve-all" }.freeze

  setup do
    # The repair pins production ids (links 45 to 92, companies 92 to 116).
    # Rows made here start past them, so none lands on a pinned id by chance:
    # which id a row got depended on the order the tests ran in.
    %w[organizations relationships].each do |table|
      ActiveRecord::Base.connection.execute("SELECT setval('#{table}_id_seq', GREATEST(1000, (SELECT last_value FROM #{table}_id_seq)))")
    end
    @doe = Organization.create!(name: "U.S. Department of Energy", **VERIFIED)
    @terrapower = Organization.create!(name: "TerraPower", **VERIFIED)
    @restored = link(@terrapower, "#{Repair::FUNDER}$1.7 billion, 2021: DENE0009054.", started_on: Date.new(2021, 1, 1))
    @bwxt = Organization.create!(name: "BWXT NUCLEAR ENERGY, INC.", **VERIFIED)
    @bwxt_link = link(@bwxt, "#{Repair::FUNDER}$99.9 million, 2023: 89233123FNA400535.", started_on: Date.new(2023, 1, 1))
    @caps = Organization.create!(name: "BROOKHAVEN TECHNOLOGY GROUP INC", **VERIFIED)
    @reworded = link(@caps, "#{Repair::FUNDER}$1.2 million, 2018: DESC0018737.")
    @nas = Organization.create!(name: "National Academy of Sciences", **VERIFIED)
  end

  def link(to, description, started_on: nil) = Relationship.create!(from_organization: @doe, to_organization: to, relationship_type: "funds", description:, started_on:, **VERIFIED)

  # The production ids pinned in the repair, pointed at this test's records.
  def with_ids(&)
    stub_const(Repair, :RESTORE, { @restored.id => [ "#{Repair::FUNDER}$1.7 billion, 2021: DENE0009054.", "ARDP award (Oct 2020): hand-written.", Date.new(2021, 1, 1) ] }) do
      stub_const(Repair, :BWXT, Repair::BWXT.merge(id: @bwxt.id)) do
        stub_const(Repair, :BWXT_LINK, Repair::BWXT_LINK.merge(id: @bwxt_link.id, was_started_on: Date.new(2023, 1, 1))) do
          stub_const(Repair, :RENAME, { @caps.id => [ "BROOKHAVEN TECHNOLOGY GROUP INC", "Brookhaven Technology Group" ] }) do
            stub_const(Repair, :REWORD, { @reworded.id => [ "$1.2 million", "2018", "DESC0018737" ] }) do
              stub_const(Repair, :OUT_OF_SCOPE, @nas.id, &)
            end
          end
        end
      end
    end
  end

  test "a dry run changes nothing; then every pinned value is repaired as human:tosin, once" do
    with_ids do
      assert_equal 6, Repair.call(dry_run: true).size
      assert_equal "TerraPower", @terrapower.reload.name
      assert_equal Date.new(2021, 1, 1), @restored.reload.started_on, "a dry run changes nothing"

      Repair.call

      assert_equal [ "ARDP award (Oct 2020): hand-written.", nil ], [ @restored.reload.description, @restored.started_on ]
      assert_equal "human:tosin", @restored.verified_by
      assert_equal Repair::REASON, @restored.verification_events.order(:id).last.reason
      assert_equal "BWXT", @bwxt.reload.name
      assert_equal [ Repair::BWXT_LINK[:description], Date.new(2018, 8, 1) ], [ @bwxt_link.reload.description, @bwxt_link.started_on ]
      assert_equal "Brookhaven Technology Group", @caps.reload.name
      assert_equal @caps.id, Directory::Lookup.organization(name: "BROOKHAVEN TECHNOLOGY GROUP INC")&.id
      assert_equal "#{Repair::FUNDER}$1.2 million (2018): DESC0018737.", @reworded.reload.description
      assert @nas.reload.unpublished?

      assert_empty Repair.call, "once"
    end
  end

  test "after a re-seed wrote the hand-written description back, it clears the start date and carries on" do
    # As the seed writes it: the DOE file's text, as human:tosin, the crawler's started_on left.
    Directory::FactWriter.write(:relationship, { id: @restored.id, description: "ARDP award (Oct 2020): hand-written." },
      verification: { status: "verified", by: "human:tosin" })
    assert_equal Date.new(2021, 1, 1), @restored.reload.started_on

    with_ids do
      changes = Repair.call
      assert_equal 6, changes.size, "the date, and every other change"
      assert_equal [ "ARDP award (Oct 2020): hand-written.", nil ], [ @restored.reload.description, @restored.started_on ]
      assert_equal "BWXT", @bwxt.reload.name
      assert_equal "Brookhaven Technology Group", @caps.reload.name
      assert @nas.reload.unpublished?

      assert_empty Repair.call, "once"
    end
  end

  test "once it has run, it's done, even when link 45 needed nothing and another fact is edited later" do
    @restored.update_columns(description: "ARDP award (Oct 2020): hand-written.", started_on: nil)

    with_ids do
      assert_equal 5, Repair.call.size, "every change but link 45's"
      @reworded.update!(description: "Edited later by hand.", decided_by: "human:tosin")

      assert_empty Repair.call, "done: a later edit isn't checked, or overwritten"
    end
    assert_equal "Edited later by hand.", @reworded.reload.description
  end

  test "it locks links before companies, as FactWriter does" do
    with_ids do
      targets = Repair.new.send(:targets)
      assert_equal %w[Relationship Organization], targets.map(&:first).uniq
      assert_equal targets.select { |type, _| type == "Relationship" }.sort, targets.select { |type, _| type == "Relationship" }
    end
  end

  test "a deadlock with another writer stops it with nothing changed, to run again next crawl" do
    collide = Module.new { def decide_fact(*, **) = raise(ActiveRecord::Deadlocked, "deadlock detected") }
    directory = DataQuality::DirectoryClient.new.extend(collide)

    with_ids do
      error = assert_raises(Repair::Mismatch) { Repair.call(directory:) }
      assert_match "nothing changed", error.message
    end
    assert_equal "TerraPower", @terrapower.reload.name
  end

  test "a start date corrected by hand stops it, with the approve-all's description or the hand-written one" do
    [ "#{Repair::FUNDER}$1.7 billion, 2021: DENE0009054.", "ARDP award (Oct 2020): hand-written." ].each do |description|
      @restored.update_columns(description:, started_on: Date.new(2020, 10, 1))
      with_ids { assert_raises(Repair::Mismatch) { Repair.call } }
      assert_equal Date.new(2020, 10, 1), @restored.reload.started_on
    end
    assert_equal "TerraPower", @terrapower.reload.name
  end

  test "BWXT's link with the repaired description but another date stops it" do
    @bwxt_link.update_columns(description: Repair::BWXT_LINK[:description], started_on: Date.new(2019, 1, 1))

    with_ids { assert_raises(Repair::Mismatch) { Repair.call } }
    assert_equal Date.new(2019, 1, 1), @bwxt_link.reload.started_on
    assert @nas.reload.verified?, "nothing at all changed"
  end

  test "the production dates are pinned as Data Quality read them" do
    assert_equal [ Date.new(2021, 5, 3), Date.new(2016, 7, 1), Date.new(2021, 3, 1) ], Repair::RESTORE.values.map(&:last)
    assert_equal [ Date.new(2023, 8, 24), Date.new(2018, 8, 1) ], Repair::BWXT_LINK.values_at(:was_started_on, :started_on)
  end

  test "BWXT renamed by hand without its legal names gets them added" do
    @bwxt.update_columns(name: "BWXT")
    @bwxt.aliases.delete_all

    with_ids do
      Repair.call
      Repair::BWXT[:aliases].each { |name| assert_equal @bwxt.id, Directory::Lookup.organization(name:)&.id, name }
      assert_equal "BWXT", @bwxt.reload.name
    end
  end

  test "a value someone fixed by hand stops the repair, and nothing at all is changed" do
    @reworded.update!(description: "Hand-fixed by Tosin.", decided_by: "human:tosin")

    with_ids do
      assert_raises(Repair::Mismatch) { Repair.call }
    end

    assert_equal "TerraPower", @terrapower.reload.name
    assert_equal "#{Repair::FUNDER}$1.7 billion, 2021: DENE0009054.", @restored.reload.description
    assert @nas.reload.verified?
  end

  test "a database without these facts is left alone" do
    assert_empty Repair.call
  end
end
