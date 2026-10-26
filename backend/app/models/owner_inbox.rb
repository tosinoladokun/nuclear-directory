# Tosin's inbox (#548, Design's spec on the issue): only what he decides.
# New companies and plants to create, new facts and deals to approve, and
# changes to something already there, each fact once (its copies from other
# pages decided with it). Everything else is Data Quality's to settle first
# (Review.inbox_kind "dq"), and a restatement has already confirmed itself.
class OwnerInbox
  # Everything he needs to do (Tosin, 26 Oct): what's new, and changes to
  # something already there.
  SECTIONS = %w[new_record new_fact change].freeze
  # changes: { field => [stored, stated] } for a change, else {}.
  Entry = Data.define(:kind, :item, :copy_ids, :checked, :changes) do
    def ids = [ item.candidate_id, *copy_ids ]
  end

  def initialize(directory: DataQuality::DirectoryClient.new)
    @directory = directory
  end

  # { [kind, …] => [candidate, …] }: each fact's copies together, newest first.
  def groups
    @groups ||= begin
      waiting = Candidate.where(id: DataQuality::Review.check_ids(category: "all"))
        .where("candidates.payload->>'lead' IS DISTINCT FROM 'true'").includes(:source).order(id: :desc).to_a
      firsts = DataQuality::Review.first_batches
      kinds = waiting.index_with { |candidate| DataQuality::Review.inbox_kind(candidate, directory: @directory, firsts:) }
      mine = waiting.select { |candidate| SECTIONS.include?(kinds[candidate]) }
      mine.group_by { |candidate| [ kinds[candidate], candidate.kind, candidate.subject_type, candidate.subject_id, candidate.payload.to_h.sort ] }
    end
  end

  # How many facts wait for him, without building their rows (the nav badge).
  def size = @sections ? sections.values.sum(&:size) : groups.size

  # { "new_record" => [Entry, …], … }, newest first.
  def sections
    @sections ||= begin
      items = DataQuality::Review.items(groups.values.map { |copies| copies.first.id }, directory: @directory).index_by(&:candidate_id)
      entries = groups.filter_map do |(kind, *), copies|
        item = items[copies.first.id] or next
        changes = kind == "change" ? changes_of(copies.first) : {}
        Entry.new(kind:, item:, copy_ids: copies.drop(1).map(&:id), checked: checked?(copies.first), changes:)
      end
      SECTIONS.index_with { |section| entries.select { |entry| entry.kind == section } }
    end
  end

  def checked = sections.values_at("new_record", "new_fact").flatten.select(&:checked)

  # What "Yes to all" takes: each checked fact's first copy as Data Quality's
  # call on it, for Recommendations.accept (rechecked under its locks).
  def checked_items
    checked.map do |entry|
      candidate = Candidate.find(entry.item.candidate_id)
      DataQuality::Recommendations::Item.new(candidate_id: candidate.id, call: candidate.dq_recommendation, reason: candidate.dq_reason,
        snapshot: candidate.dq_payload_sha256, claim: nil, subject_type: candidate.subject_type, subject_id: candidate.subject_id, why: nil, waiting: true)
    end
  end
  def checkable = sections.values_at("new_record", "new_fact").flatten

  # Decisions a person made in the last week, newest first.
  def recent(limit: 50)
    Candidate.where(status: %w[merged rejected], reviewed_at: 7.days.ago..).where("reviewed_by LIKE 'human:%'")
      .includes(:source).order(reviewed_at: :desc).limit(limit)
  end

  private
    # Data Quality said approve, and the claim is still as it looked at it.
    def changes_of(candidate)
      record = @directory.fact(type: candidate.subject_type, id: candidate.subject_id) or return {}
      changes = DataQuality::Differences.changes(candidate, record, directory: @directory).to_h
      # A unit joining its site is a change too, though no field says so.
      if candidate.kind == "facility" && (site_id = @directory.site_for_unit(candidate))
        changes["parent_name"] = [ nil, @directory.fact(type: "Facility", id: site_id)&.name ]
      end
      changes
    end

    def checked?(candidate) = candidate.dq_recommendation == "approve" && DataQuality::Recommendations.current?(candidate)
end
