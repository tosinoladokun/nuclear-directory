# PM, 24 Oct 2026: EIA's September monthly generator file (860M) was read as a
# new source, so its rows restating values Tosin had already approved waited
# in his queue (152 of them, no conflicts): a new file had no evidence on
# those units yet. Match now confirms a new issue of a dated source on its
# own (FactWriter#confirm, source_kind:). This closes the ones already
# waiting the same way, as Close (Review.confirm_identical) would: each only
# when it still states exactly what the unit records, adding the new file's
# evidence. Anything that differs stays for a person. Merging this PR is
# Tosin's approval.
#
# Idempotent: a closed claim isn't open any more, so a rerun closes nothing.
class SettleEiaMonthlyRestatements < DeployData::Migration
  BY = "human:tosin"
  SOURCE_KIND = "eia_generators"

  def up
    ids = Candidate.joins(:source).where(sources: { source_kind: SOURCE_KIND }, status: %w[new matched needs_review])
      .where.not(subject_id: nil).order(:id).ids
    results = DataQuality::Review.confirm_identical(ids, by: BY)
    closed, left = results.partition(&:ok?)
    say "Closed #{closed.size} EIA monthly claims that restate what their unit records; #{left.size} still differ and wait for a person"
  end
end
