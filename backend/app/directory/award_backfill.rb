# Award deal terms from the USAspending rows already stored (#256): one
# term per award ID under the DOE funds link it supports. The one code path
# behind `directory:backfill_award_terms` and the deploy's one-time data
# step.
#
# Each open funds link reads its own USAspending sources, and those of a
# funds link a company merge retired into it (either end, merges of merges
# followed). A term takes its link's state: verified, by `by`, only on a link
# a person verified; otherwise pending, waiting with the link. An award any
# of those links already has, in any state, is left alone, so a rerun writes
# nothing new and a term a person rejected isn't written again.
#
#   Directory::AwardBackfill.new(by: "human:tosin").run(apply: false)
#   # => Result(on_verified: 30, on_pending: 22, already: 0, failed: 0, lines: [...])
class Directory::AwardBackfill
  Result = Data.define(:on_verified, :on_pending, :already, :failed, :lines) do
    def written = on_verified + on_pending

    def summary(apply:)
      verb = apply ? "written" : "would be written"
      [ "#{written} award terms #{verb}, #{already} already there#{", #{failed} failed" if failed.positive?}.",
        "#{on_verified} on verified links (written verified), #{on_pending} on pending links (written pending)." ]
    end
  end

  REASON = "Backfilled from its link's USAspending rows (#256)".freeze

  def initialize(by:, reason: nil)
    raise ArgumentError, "a backfill is a person's decision (by: \"human:…\")" unless by.to_s.match?(/\Ahuman:\S+\z/)

    @by = by
    @reason = [ REASON, reason ].compact.join("; ")
  end

  def run(apply:)
    counts = Hash.new(0)
    lines = []
    Relationship.where(relationship_type: "funds").where.not(verification_status: Verifiable::CLOSED_STATUSES).order(:id).each do |link|
      links = [ link, *retired_into(link) ]
      sources = Source.where(source_kind: "usaspending_doe_awards", id: Evidence.where(subject: links).select(:source_id))
      sources.each do |source|
        CSV.parse(source.content_text, headers: true).each do |row|
          next if row["generated_award_id"].blank?

          # Already handled when any of these links has it, in any state: a
          # term a person rejected isn't written again on the kept link.
          next counts[:already] += 1 if DealTerm.where(link: links, term_type: "award", external_id: row["generated_award_id"]).exists?

          bucket = link.human_verified? ? :on_verified : :on_pending
          next counts[bucket] += 1 unless apply

          result = write(link, source, row)
          next counts[bucket] += 1 if result.ok?

          counts[:failed] += 1
          lines << "link #{link.id}, award #{row["generated_award_id"]}: #{result.errors.join('; ')}"
        end
      end
    end
    Result.new(on_verified: counts[:on_verified], on_pending: counts[:on_pending], already: counts[:already], failed: counts[:failed], lines:)
  end

  private
    def write(link, source, row)
      verification = { status: "verified", by: @by, reason: @reason } if link.human_verified?
      Directory::FactWriter.write(:deal_term, {
        link_type: "Relationship", link_id: link.id, term_type: "award", external_id: row["generated_award_id"],
        amount_usd: row["amount_usd"], starts_on: row["start_date"], ends_on: row["end_date"].presence,
        program: row["assistance_listing"].presence || row["award_type"]
      }, evidence: [ { source_id: source.id, quote: row.to_csv.chomp, found_by: "crawler" } ], verification:,
        # Locks the link and refuses it if a merge closed it since it was
        # read, so a rerun writes onto the link the merge kept.
        protect_human_verified: true)
    end

    # The funds links a company merge retired into this one: between
    # companies merged into either end, and only a link the merge itself
    # retired (its last decision is the merge's rejection, "Merged into …",
    # #229). A link a person closed before the merge stays closed.
    def retired_into(link)
      funders = [ link.from_organization_id, *merged_into(link.from_organization_id) ]
      recipients = [ link.to_organization_id, *merged_into(link.to_organization_id) ]
      Relationship.where(from_organization_id: funders, to_organization_id: recipients, relationship_type: "funds",
        verification_status: "rejected").where.not(id: link.id).select do |other|
        other.verification_events.order(:id).last&.reason.to_s.match?(/Merged into .+ \(#\d+\)/)
      end
    end

    # Every company merged into this one, at any depth (A into B, then B into C).
    def merged_into(company_id)
      @merged_into ||= {}
      @merged_into[company_id] ||= begin
        found = []
        frontier = [ company_id ]
        while frontier.any?
          frontier = VerificationEvent.where(subject_type: "Organization", to_status: "unpublished")
            .where("context -> 'merged_into' ->> 'id' IN (?)", frontier.map(&:to_s)).pluck(:subject_id) - found
          found += frontier
        end
        found
      end
    end
end
