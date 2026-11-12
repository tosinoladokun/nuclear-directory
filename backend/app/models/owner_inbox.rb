# Tosin's inbox (#548, Design's spec on the issue): only what he decides.
# New companies and plants to create, new facts and deals to approve, and
# changes to something already there, each fact once (its copies from other
# pages decided with it). Everything else is Data Quality's to settle first
# (Review.inbox_kind "dq"), and a restatement has already confirmed itself.
class OwnerInbox
  # Everything he needs to do (Tosin, 26 Oct): what's new, and changes to
  # something already there.
  RECORDS = 200
  # New companies to create, at most this many a day (PM, 10 Nov): the rest wait for the next day,
  # best-sourced first. Plants aren't counted.
  CREATES_A_DAY = 10
  SECTIONS = %w[new_record new_fact change].freeze
  # changes: { field => [stored, stated] } for a change, else {}.
  Entry = Data.define(:kind, :item, :copy_ids, :checked, :changes) do
    def ids = [ item.candidate_id, *copy_ids ]
  end

  def initialize(directory: DataQuality::DirectoryClient.new)
    @directory = directory
    @companions = {}
  end

  # { [kind, …] => [candidate, …] }: each fact's copies together, newest first.
  def groups
    @groups ||= begin
      # Plus open claims Data Quality approved, which may have no checker verdict yet.
      approved = Candidate.where(status: DataQuality::Recommendations::OPEN, dq_recommendation: "approve").select(:id)
      waiting = Candidate.where(id: DataQuality::Review.check_ids(category: "all")).or(Candidate.where(id: approved))
        .where("candidates.payload->>'lead' IS DISTINCT FROM 'true'").includes(:source).order(id: :desc).to_a
      firsts = DataQuality::Review.first_batches
      kinds = waiting.index_with { |candidate| DataQuality::Review.inbox_kind(candidate, directory: @directory, firsts:) }
      mine = waiting.select { |candidate| SECTIONS.include?(kinds[candidate]) }
      # A new company's field claims (#760) are decided with its Create, not on their own.
      fields = DataQuality::FieldEvidence.fields_of(mine.select { |c| kinds[c] == "new_record" && c.kind_organization? }.map(&:id))
        .where.not(subject_id: nil).to_a.group_by { |c| c.payload["field_of"].to_i }
      field_ids = fields.values.flatten.map(&:id).to_set
      grouped = mine.reject { |candidate| field_ids.include?(candidate.id) }
        .group_by { |candidate| [ kinds[candidate], candidate.kind, candidate.subject_type, candidate.subject_id, candidate.payload.to_h.sort ] }
      # Only the fields checked against their own pages go with the Create; the rest wait (Review.approve_one rechecks).
      grouped = grouped.transform_values do |copies|
        copies + copies.flat_map { |copy| fields.fetch(copy.id, []).select { |f| DataQuality::FieldEvidence.ready?(f, copy.subject_id) } }
      end
      one_create_per_company(grouped)
    end
  end

  # How many facts wait for him, without building their rows (the nav badge).
  def size
    capped = groups.size - company_groups.size + company_groups.count { |_, copies| shown_companies.include?(copies.first.subject_id) }
    (@sections ? sections.values.sum(&:size) : capped) + records.size
  end

  # Pending companies and plants with no open claim (seeded, or a claim
  # decided since): his too, decided on the record itself.
  def records
    # The day's new-company claims come first; pending companies fill what's left of today's share.
    @records ||= pending_records("facility") + pending_records("organization").first(company_records_left)
  end

  # New companies he can still create today: CREATES_A_DAY less the ones he decided (created or said no) today.
  def creates_left(now: Time.current)
    @creates_left ||= begin
      decided = VerificationEvent.where(subject_type: "Organization", from_status: "pending", to_status: %w[verified rejected],
        created_at: now.all_day).where("verification_events.by LIKE 'human:%'").distinct.count(:subject_id)
      [ CREATES_A_DAY - decided, 0 ].max
    end
  end

  # New companies waiting beyond today's share.
  def companies_waiting = (ranked_companies.size - shown_companies.size) + (pending_company_count - company_records_left).clamp(0..)

  # Every pending company with a sourced role and no open claim, however many (not just the rows fetched).
  def pending_company_count = (@pending_company_count ||= pending_records("organization", limit: 10_000).size)
  def company_records_left = [ creates_left - shown_companies.size, 0 ].max

  # The new-company claim groups (a company's pages may give different fields, so a company can have several).
  def company_groups = groups.select { |(kind, candidate_kind, *), _| kind == "new_record" && candidate_kind == "organization" }

  # What makes a new company complete enough to Create without gaps (Data Quality, 10 Nov).
  COMPLETE = %w[website description hq_city].freeze

  # The new companies with open claims, by company: most complete first (website, description, HQ, on the
  # record or in its claims), then best-sourced (most distinct pages naming it), then newest.
  def ranked_companies
    @ranked_companies ||= begin
      by_company = company_groups.flat_map { |_, copies| copies }.group_by(&:subject_id)
      stored = Organization.where(id: by_company.keys).pluck(:id, *COMPLETE).to_h { |id, *values| [ id, COMPLETE.zip(values).to_h ] }
      complete = ->(id, claims) { COMPLETE.count { |field| stored.dig(id, field).present? || claims.any? { |c| c.payload[field].present? } } }
      by_company.sort_by { |id, claims| [ -complete.call(id, claims), -claims.map(&:source_id).uniq.size, -claims.map(&:id).max ] }.map(&:first)
    end
  end

  # Today's share of them.
  def shown_companies = (@shown_companies ||= ranked_companies.first(creates_left).to_set)

  # Up to `limit` pending records of a kind, paging past companies without a
  # sourced category (role; PM, 28 Oct) so they never hide eligible ones.
  # Roles are looked up per page, in one query.
  def pending_records(kind, limit: RECORDS)
    found = []
    after_id = nil
    loop do
      page = DataQuality::Review.pending_facts(kind:, after_id:, limit:, directory: @directory)
      if kind == "organization"
        with_role = @directory.sourced_role_ids(page.map(&:id))
        found.concat(page.select { |fact| with_role.include?(fact.id) })
      else
        found.concat(page)
      end
      break if found.size >= limit || page.size < limit

      after_id = page.last.id
    end
    found.first(limit)
  end

  # { "new_record" => [Entry, …], … }, newest first.
  def sections
    @sections ||= begin
      items = DataQuality::Review.items(groups.values.map { |copies| copies.first.id }, directory: @directory).index_by(&:candidate_id)
      entries = groups.filter_map do |(kind, *), copies|
        item = items[copies.first.id] or next
        changes = kind == "change" ? changes_of(copies.first) : {}
        Entry.new(kind:, item:, copy_ids: copies.drop(1).map(&:id), checked: checked?(copies.first), changes:)
      end
      by_section = SECTIONS.index_with { |section| entries.select { |entry| entry.kind == section } }
      by_section["new_record"] = todays_share(by_section["new_record"])
      by_section
    end
  end

  def checked = checkable.select(&:checked)

  # What "Yes to all" takes: each checked fact's first copy as Data Quality's
  # call on it, for Recommendations.accept (rechecked under its locks).
  def checked_items
    checked.map do |entry|
      candidate = Candidate.find(entry.item.candidate_id)
      DataQuality::Recommendations::Item.new(candidate_id: candidate.id, call: candidate.dq_recommendation, reason: candidate.dq_reason,
        snapshot: candidate.dq_payload_sha256, claim: nil, subject_type: candidate.subject_type, subject_id: candidate.subject_id, why: nil, waiting: true)
    end
  end
  # A pending company's other checked claims shown with its Create (one Create per company), by the Create's claim id.
  def companions_of(candidate_ids)
    groups
    candidate_ids.flat_map { |id| @companions.fetch(id, []) }
  end

  # Whether a company's other claim goes with its Create: Data Quality approved this very payload (only its approve,
  # never the verifier's alone, and never one it said no to: DQ, 12 Nov); its quote still in its page; nothing contradicts it. Checked again when it's decided.
  def self.rides_along?(claim, company_id)
    claim.subject_id == company_id && claim.status.in?(%w[new matched needs_review]) &&
      claim.dq_recommendation == "approve" && DataQuality::Recommendations.current?(claim) &&
      !DataQuality::Review.contradicted?(claim) && quote_in_source?(claim)
  end

  def self.quote_in_source?(candidate)
    return false if candidate.quote.blank?

    check = DataQuality::Review.in_source(candidate) || ->(quote) { candidate.source.content_text.to_s.include?(quote.to_s) }
    check.call(candidate.quote)
  end

  # What "Yes to all" was shown: its items, and the field claims (#760) and companions going with them, as they were.
  def yes_all_fingerprint
    ids = checked_items.map(&:candidate_id)
    fields = DataQuality::FieldEvidence.fields_of(ids).or(Candidate.where(id: companions_of(ids))).order(:id)
      .map { |f| [ f.id, f.status, f.subject_id, f.payload, f.quote, f.ai_recommendation ] }
    Digest::SHA256.hexdigest([ DataQuality::Recommendations.fingerprint(checked_items), fields ].to_json)
  end

  # New records and facts, and changes that only fill blanks (#676).
  def checkable = sections.values_at("new_record", "new_fact").flatten + sections["change"].select { |entry| entry.changes.present? && entry.changes.values.all? { |(stored, _)| stored.blank? } }

  # Decisions a person made in the last week, newest first.
  def recent(limit: 50)
    Candidate.where(status: %w[merged rejected], reviewed_at: 7.days.ago..).where("reviewed_by LIKE 'human:%'")
      .includes(:source).order(reviewed_at: :desc).limit(limit)
  end

  private
    # A pending company is one Create (Data Quality, 11 Nov): its other claims (a website, a description, a
    # role from its own page) go with that row, not as Creates of their own. Those checked (the checker agreed
    # or Data Quality approved, quote still in its page, not contradicted) ride along; the rest wait.
    def one_create_per_company(grouped)
      creates = grouped.select { |(kind, candidate_kind, *), _| kind == "new_record" && candidate_kind == "organization" }
      by_company = creates.group_by { |_, copies| copies.first.subject_id }
      # He said No to the company (its proposing claim is rejected): what's left on it stays with Data Quality.
      declined = Candidate.where(subject_type: "Organization", subject_id: by_company.keys, proposed_subject: true, status: "rejected").distinct.pluck(:subject_id)
      by_company.each do |company_id, rows|
        primary = rows.find { |_, copies| copies.any?(&:proposed_subject) }
        if primary.nil? && declined.include?(company_id)
          rows.each { |key, _| grouped.delete(key) }
          next
        end
        next if rows.size < 2

        primary ||= rows.min_by { |_, copies| copies.map(&:id).min }
        (rows - [ primary ]).each do |key, copies|
          grouped.delete(key)
          riders = copies.select { |claim| self.class.rides_along?(claim, company_id) }
          primary.last.concat(riders)
          (@companions[primary.last.first.id] ||= []).concat(riders.map(&:id))
        end
      end
      grouped
    end

    # Today's share of new companies, best-sourced first (most pages naming it), then newest; plants all.
    def todays_share(new_records)
      subject = company_groups.to_h { |_, copies| [ copies.first.id, copies.first.subject_id ] }
      order = ranked_companies.each_with_index.to_h
      new_records.reject { |entry| (id = subject[entry.item.candidate_id]) && !shown_companies.include?(id) }
        .sort_by.with_index { |entry, i| [ order.fetch(subject[entry.item.candidate_id], order.size), i ] }
    end

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

    # Data Quality's own approve, still current, counts for "Yes to all N"
    # even where the checker doubted (PM, 27 Oct); the row shows both. Never
    # a claim the checker contradicted with a different value, and only while
    # its quote is still in the source, as Accept checks.
    def checked?(candidate)
      candidate.dq_recommendation == "approve" && DataQuality::Recommendations.current?(candidate) &&
        !DataQuality::Review.contradicted?(candidate) && quote_in_source?(candidate)
    end

    def quote_in_source?(candidate) = self.class.quote_in_source?(candidate)
end
