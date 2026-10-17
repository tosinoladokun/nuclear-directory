# One-time repair of the 16 Oct 2026 20:41 UTC "Approve all", which
# published the DOE crawl's first batch (#302) before it was reviewed:
# - 3 hand-written link descriptions (TerraPower, X-energy, CFS) were
#   replaced by award summaries, with a crawler start date: restored from
#   db/seeds/organizations/us-department-of-energy.yml, start date cleared
# - BWXT (company 98) was published under its award spelling, and its link
#   (72) lost its 2018 award: renamed "BWXT", the link sums up both awards
# - 23 companies were published under all-capitals award spellings:
#   renamed with the plug-in's display name, the spelling kept as an alias
# - 20 one-award links read "…, 2021: ID": reworded "… (2021): ID"
# - National Academy of Sciences (107) is out of scope: taken off
#
# The USAspending evidence stays on every fact as another source.
#
# Data Quality pinned every value the approve-all left. Each fact is checked
# first: one already repaired is skipped; one that's neither (someone fixed
# it by hand) stops the repair, which then changes nothing at all. It runs
# as human:tosin (his approval of the PR), at the start of the DOE crawl, so
# it needs no shell; once its reason is in the history it does nothing.
# dry_run: everything is checked and written, then rolled back.
class DataQuality::Repairs::ApproveAll20261016
  BY = "human:tosin"
  REASON = "Repair after the 16 Oct 20:41 approve-all of DOE awards (#302)"
  FUNDER = "1 award from the U.S. Department of Energy totaling "

  # Link id => [the approve-all's description (its start), the hand-written
  # one, the start date the approve-all set] (Data Quality, 17 Oct backup and
  # production).
  RESTORE = {
    45 => [ "#{FUNDER}$1.7 billion, 2021: DENE0009054.",
      "ARDP award (Oct 2020): $80M initial funding to demonstrate Natrium; cost-shared, DOE total up to $3.2B over seven years across both ARDP demos subject to appropriations.",
      Date.new(2021, 5, 3) ],
    46 => [ "4 awards from the U.S. Department of Energy totaling $967.5 million, 2016–2023: DENE0009040, DENE0008472, DENE0008745 and 1 more.",
      "ARDP award (Oct 2020): $80M initial funding for a four-unit Xe-100 plant and TRISO fuel fabrication facility; cost-shared.",
      Date.new(2016, 7, 1) ],
    48 => [ "#{FUNDER}$1.5 million, 2021: DESC0021623.",
      "Selected (May 2023) in the $46M Milestone-Based Fusion Development Program; payments only on verified milestones.",
      Date.new(2021, 3, 1) ]
  }.freeze
  BWXT = { id: 98, was: "BWXT NUCLEAR ENERGY, INC.", name: "BWXT", aliases: [ "BWXT NUCLEAR ENERGY, INC.", "BWXT NUCLEAR OPERATIONS GROUP, INC." ] }.freeze
  BWXT_LINK = { id: 72, was: "#{FUNDER}$99.9 million, 2023: 89233123FNA400535.", was_started_on: Date.new(2023, 8, 24), started_on: Date.new(2018, 8, 1),
    description: "2 awards from the U.S. Department of Energy totaling $102.6 million (first in 2018, latest in 2023): 89233123FNA400535 and DENE0008744." }.freeze
  # Company id => [its name as the approve-all left it, the name it takes] (Data Quality, 16 Oct).
  RENAME = {
    92 => [ "ADVANCED REACTOR CONCEPTS, LLC", "Advanced Reactor Concepts" ],
    93 => [ "CERAMIC TUBULAR PRODUCTS LLC", "Ceramic Tubular Products" ],
    94 => [ "BLUE WAVE CAPITAL AND CONSULTING LLC", "Blue Wave Capital and Consulting" ],
    95 => [ "NUVISION ENGINEERING, INC", "NuVision Engineering" ],
    96 => [ "CONTAINER TECHNOLOGIES INDUSTRIES, LLC", "Container Technologies Industries" ],
    97 => [ "ELECTRIC POWER RESEARCH INSTITUTE INC", "Electric Power Research Institute" ],
    99 => [ "ANALYSIS AND MEASUREMENT SERVICES CORPORATION", "Analysis and Measurement Services" ],
    100 => [ "PKMJ TECHNICAL SERVICES, LLC", "PKMJ Technical Services" ],
    101 => [ "3M COMPANY", "3M" ],
    102 => [ "NAC INTERNATIONAL INC.", "NAC International" ],
    103 => [ "GOOD ENERGY COLLECTIVE INCORPORATED", "Good Energy Collective" ],
    104 => [ "NUCLEAR FUEL SERVICES INC", "Nuclear Fuel Services" ],
    105 => [ "ENSCO INC", "ENSCO" ],
    106 => [ "LEIDOS, INC.", "Leidos" ],
    108 => [ "LODESTAR RESEARCH CORPORATION", "Lodestar Research" ],
    109 => [ "NUSENICS, LLC", "Nusenics" ],
    110 => [ "AQWEST, LLC", "Aqwest" ],
    111 => [ "AMPEERS LLC", "Ampeers" ],
    112 => [ "SYDOR INSTRUMENTS, LLC", "Sydor Instruments" ],
    113 => [ "PLASMA PROCESSES, LLC", "Plasma Processes" ],
    114 => [ "XUV LASERS, INC.", "XUV Lasers" ],
    115 => [ "BRIDGE 12 TECHNOLOGIES, INC.", "Bridge12" ],
    116 => [ "BROOKHAVEN TECHNOLOGY GROUP INC", "Brookhaven Technology Group" ]
  }.freeze
  # One-award link id => [amount, year, award id] as the approve-all wrote them (Data Quality, 16 Oct).
  REWORD = {
    63 => [ "$73.2 million", "2021", "DENE0009042" ],
    65 => [ "$20.2 million", "2021", "DENE0009223" ],
    66 => [ "$10.5 million", "2021", "DENE0008925" ],
    69 => [ "$3.0 million", "2019", "DENE0008816" ],
    70 => [ "$3.0 million", "2026", "DENE0009542" ],
    75 => [ "$1.9 million", "2024", "DENE0009345" ],
    76 => [ "$1.7 million", "2026", "DENE0009540" ],
    77 => [ "$1.7 million", "2023", "DENE0009335" ],
    79 => [ "$900.0 million", "2026", "89243226FNE400213" ],
    81 => [ "$4.7 million", "2022", "89243222CNE000026" ],
    82 => [ "$4.3 million", "2022", "89243222FNE400082" ],
    84 => [ "$4.8 million", "1996", "DEFG0297ER54392" ],
    85 => [ "$2.5 million", "2022", "DESC0022578" ],
    86 => [ "$2.2 million", "2016", "DESC0015834" ],
    87 => [ "$1.4 million", "2024", "DESC0024754" ],
    88 => [ "$1.4 million", "2023", "DESC0023913" ],
    89 => [ "$1.3 million", "2020", "DESC0020701" ],
    90 => [ "$1.3 million", "2023", "DESC0023878" ],
    91 => [ "$1.3 million", "2019", "DESC0019918" ],
    92 => [ "$1.2 million", "2018", "DESC0018737" ]
  }.freeze
  OUT_OF_SCOPE = 107

  # A value that's neither what the approve-all left nor the repaired one.
  class Mismatch < StandardError; end

  # One write: kind and id, the attributes it sets, the status it leaves.
  Change = Data.define(:kind, :id, :attributes, :status, :note)

  def self.call(...) = new(...).call

  def initialize(dry_run: false, directory: DataQuality::DirectoryClient.new)
    @dry_run = dry_run
    @directory = directory
  end

  # The changes made (or, in a dry run, that would be). [] once done.
  def call
    return [] if done?

    changes = []
    ActiveRecord::Base.transaction(requires_new: true) do
      # Every fact it touches is locked first and checked under the lock, so
      # a correction made meanwhile stops the repair rather than being overwritten.
      targets.each { |type, id| @directory.lock_fact(type:, id:) }
      changes = plan
      changes.each do |change|
        result = @directory.decide_fact(change.kind, id: change.id, status: change.status, by: BY, reason: REASON, attributes: change.attributes)
        raise Mismatch, "#{change.kind} #{change.id}: #{result.errors.to_sentence}" if result.errors.any?
      end
      raise ActiveRecord::Rollback if @dry_run
    end
    changes
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    # Another writer held one of its facts: nothing was changed; the next crawl tries again.
    raise Mismatch, "another write held one of its facts just then; nothing changed, it runs again with the next crawl"
  end

  # Every change, checked against what the approve-all left; raises Mismatch first.
  def plan
    [ *RESTORE.filter_map { |id, (was, written, started)| restore(id, was, written, started) }, *bwxt,
      *RENAME.filter_map { |id, (was, name)| rename(id, was, name) }, *REWORD.filter_map { |id, award| reword(id, *award) }, take_down ].compact
  end

  private
    # [type, id] of every fact the repair may write: links first, then
    # companies, each by id, the order FactWriter locks them in (a link, then
    # its ends), so a write running alongside never waits on this one while
    # this one waits on it.
    def targets
      links = [ *RESTORE.keys, BWXT_LINK[:id], *REWORD.keys ].uniq.sort.map { |id| [ "Relationship", id ] }
      companies = [ BWXT[:id], *RENAME.keys, OUT_OF_SCOPE ].uniq.sort.map { |id| [ "Organization", id ] }
      links + companies
    end

    # Done, or not this database (a test or local one without these facts).
    # Done when any fact it may write carries its reason: a run records it on
    # every fact it changes, whichever were left to change (a re-seed that
    # ran first may have repaired link 45 already).
    def done?
      link = @directory.fact(type: "Relationship", id: RESTORE.keys.first) or return true
      return true if link.values["from_organization_name"] != "U.S. Department of Energy"

      targets.any? { |type, id| @directory.verification_history(type:, id:).any? { |event| event.reason.to_s.start_with?(REASON) } }
    end

    def fact(type, id) = @directory.fact(type:, id:) || raise(Mismatch, "#{type} #{id} is gone")

    # A re-seed that ran first (DQ, 17 Oct) has already written the
    # hand-written description back from the DOE seed file, but not cleared
    # the crawler's start date: that's half done, so only the date is
    # cleared. Anything other than the approve-all's text or the hand-written
    # one stops the repair.
    #
    # Description and date are checked as a pair. The only states it accepts:
    # the approve-all's (its text and date), after a re-seed (the
    # hand-written text, the approve-all's date) and repaired (the
    # hand-written text, no date). A date corrected by hand stops it.
    def restore(id, was, written, started)
      link = fact("Relationship", id)
      state = [ link.values["description"].to_s, date(link.values["started_on"]) ]
      case state
      when [ written, nil ] then nil
      when [ written, started ]
        Change.new(kind: "relationship", id:, attributes: { started_on: nil }, status: link.verification_status,
          note: "clears the crawler's start date (the seed already restored the description)")
      when [ was, started ]
        Change.new(kind: "relationship", id:, attributes: { description: written, started_on: nil }, status: link.verification_status,
          note: "restores the hand-written description")
      else
        raise Mismatch, "link #{id} reads #{state.first.inspect}, started #{state.last.inspect}: not the approve-all's #{was.inspect}, started #{started}"
      end
    end

    # A date as stored, whether the lookup gives a Date or its ISO text.
    def date(value) = value.presence && Date.parse(value.to_s)

    def bwxt
      company = fact("Organization", BWXT[:id])
      link = fact("Relationship", BWXT_LINK[:id])
      changes = []
      unless company.name == BWXT[:name]
        raise Mismatch, "company #{BWXT[:id]} is #{company.name.inspect}, not #{BWXT[:was].inspect}" unless company.name == BWXT[:was]

        changes << Change.new(kind: "organization", id: BWXT[:id], attributes: { name: BWXT[:name], aliases: BWXT[:aliases] },
          status: company.verification_status, note: "renamed BWXT")
      end
      # Description and date as a pair, as in restore: repaired, or exactly as the approve-all left it.
      state = [ link.values["description"].to_s, date(link.values["started_on"]) ]
      unless state == [ BWXT_LINK[:description], BWXT_LINK[:started_on] ]
        raise Mismatch, "link #{BWXT_LINK[:id]} reads #{state.first.inspect}, started #{state.last.inspect}" unless
          state == [ BWXT_LINK[:was], BWXT_LINK[:was_started_on] ]

        changes << Change.new(kind: "relationship", id: BWXT_LINK[:id], status: link.verification_status, note: "both awards",
          attributes: { description: BWXT_LINK[:description], started_on: BWXT_LINK[:started_on] })
      end
      changes
    end

    def rename(id, was, name)
      company = fact("Organization", id)
      return if company.name == name
      raise Mismatch, "company #{id} is #{company.name.inspect}, not #{was.inspect}" unless company.name == was

      Change.new(kind: "organization", id:, attributes: { name:, aliases: [ was ] }, status: company.verification_status, note: "#{was} -> #{name}")
    end

    def reword(id, amount, year, award)
      link = fact("Relationship", id)
      description = link.values["description"].to_s
      written = "#{FUNDER}#{amount} (#{year}): #{award}."
      return if description == written
      was = "#{FUNDER}#{amount}, #{year}: #{award}."
      raise Mismatch, "link #{id} reads #{description.inspect}, not #{was.inspect}" unless description == was

      Change.new(kind: "relationship", id:, attributes: { description: written }, status: link.verification_status, note: "reworded")
    end

    def take_down
      company = fact("Organization", OUT_OF_SCOPE)
      return if company.verification_status == "unpublished"
      raise Mismatch, "company #{OUT_OF_SCOPE} is #{company.verification_status}" unless company.verification_status == "verified"

      Change.new(kind: "organization", id: OUT_OF_SCOPE, attributes: {}, status: "unpublished", note: "taken off: out of scope")
    end
end
