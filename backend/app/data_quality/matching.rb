# Data Quality's matching actions (#548, option a): its agent settles a
# company claim that isn't attached to a record yet, so Tosin only sees what's
# new. Nothing here verifies or publishes: a new company is pending until his
# Create, a new name for a company he decided waits as a Change, and every
# action is recorded (DqAction) with its reason and can be undone.
#
#   DataQuality::Matching.apply([{ "id" => 12, "action" => "same_as", "target" => 40, "reason" => "…" }])
#   # => [{ id: 12, ok: true, error: nil, created_ids: [] }]
#
# same_as:       attach it to an existing company (target: its id or exact
#                name). A claim that only names it another way confirms with its
#                quote as evidence; add_alias: true keeps the name as a Change.
# new:           a pending company from the claim, for Tosin's Create / No.
# subsidiary_of: a pending company, plus a pending "subsidiary of" link to
#                the target, both for his decision.
# close:         reject the claim with the reason; a lead's name stays in Leads.
module DataQuality::Matching
  BY = "agent:data-quality"
  OPEN = %w[new needs_review].freeze
  # Stops an action part-way: everything it wrote rolls back, and the message is the row's error.
  class Abort < StandardError; end

  Row = Data.define(:id, :ok, :error, :created_ids) do
    def to_h = { id:, ok:, error:, created_ids: }
  end

  def self.apply(rows, directory: DataQuality::DirectoryClient.new)
    Array(rows).map { |row| apply_one(row.to_h.stringify_keys, directory) }
  end

  def self.apply_one(row, directory)
    id, action, reason = row["id"].to_i, row["action"].to_s, row["reason"].to_s.squish
    fail_with = ->(why) { Row.new(id:, ok: false, error: why, created_ids: []) }
    return fail_with.call("action must be one of #{DqAction::ACTIONS.join(', ')}") unless DqAction::ACTIONS.include?(action)
    return fail_with.call("give a reason") if reason.blank?

    Candidate.transaction do
      candidate = Candidate.lock.find_by(id:) or next fail_with.call("no claim ##{id}")
      # Sent again: the same action already done is fine, nothing more happens.
      done = DqAction.live.find_by(candidate_id: id, action:)
      next Row.new(id:, ok: true, error: nil, created_ids: done.created.map { |ref| ref["id"] }) if done
      next fail_with.call("it isn't a company claim") unless candidate.kind == "organization"
      next fail_with.call("it's already attached or decided (#{candidate.status})") unless OPEN.include?(candidate.status) && candidate.subject_id.nil?

      before = candidate.slice(:status, :subject_type, :subject_id, :proposed_subject, :notes, :reviewed_by, :reviewed_at).as_json
      created = []
      error = case action
      when "same_as" then same_as(candidate, row, reason, directory)
      when "new" then propose(candidate, reason, directory, created)
      when "subsidiary_of" then subsidiary_of(candidate, row, reason, directory, created)
      when "close" then close(candidate, reason, directory)
      end
      raise Abort, error if error

      DqAction.create!(candidate:, action:, target: row["target"]&.to_s, reason:, before:, created:, by: BY)
      Row.new(id:, ok: true, error: nil, created_ids: created.map { |ref| ref["id"] })
    end
  rescue Abort => e
    Row.new(id: row["id"].to_i, ok: false, error: e.message, created_ids: [])
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    Row.new(id: row["id"].to_i, ok: false, error: "someone was deciding on it just then; try again", created_ids: [])
  end

  # Undo one action, while what it did is still as it left it. Returns an error or nil.
  def self.undo(action_id, directory: DataQuality::DirectoryClient.new)
    Candidate.transaction do
      action = DqAction.lock.find_by(id: action_id) or raise Abort, "no action ##{action_id}"
      raise Abort, "it was undone already" if action.undone_at

      candidate = Candidate.lock.find(action.candidate_id)
      after = { "same_as" => %w[matched confirmed], "new" => %w[matched], "subsidiary_of" => %w[matched], "close" => %w[rejected] }
      raise Abort, "the claim was decided since, so it can't be undone here" unless after.fetch(action.action).include?(candidate.status) &&
        candidate.reviewed_by.in?([ nil, BY ])

      # What it created goes too, but only while it's still pending.
      action.created.each do |ref|
        raise Abort, "#{ref['type']} ##{ref['id']} was decided since" unless directory.fact(type: ref["type"], id: ref["id"])&.verification_status == "pending"

        Candidate.find_by(id: ref["candidate_id"])&.update!(status: "rejected", reviewed_by: BY, reviewed_at: Time.current, notes: "Undone by Data Quality") if ref["candidate_id"]
        errors = directory.decide_fact(ref["type"].underscore, id: ref["id"], status: "rejected", by: BY, reason: "Data Quality undid #{action.action}").errors
        raise Abort, errors.to_sentence if errors.any?
      end
      candidate.update!(action.before.slice("status", "subject_type", "subject_id", "proposed_subject", "notes", "reviewed_by", "reviewed_at"))
      action.update!(undone_at: Time.current)
      nil
    end
  rescue Abort => e
    e.message
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    "someone was deciding on it just then; try again"
  end

  class << self
    private
      # target: a company id, or a name that names exactly one open company.
      def target(row, directory)
        value = row["target"]
        return [ nil, "give the company it's the same as (its id or exact name)" ] if value.blank?

        if value.to_s.match?(/\A\d+\z/)
          record = directory.fact(type: "Organization", id: value.to_i)
          return [ nil, "no company ##{value}" ] unless record && %w[verified pending].include?(record.verification_status)

          return [ record, nil ]
        end
        ids = directory.organization_ids_named(value.to_s)
        return [ nil, "no company named #{value.to_s.inspect}; give its id" ] if ids.empty?
        return [ nil, "#{value.to_s.inspect} names #{ids.size} companies (##{ids.join(', #')}); give the id" ] if ids.size > 1

        [ directory.fact(type: "Organization", id: ids.first), nil ]
      end

      def same_as(candidate, row, reason, directory)
        record, error = target(row, directory)
        return error if error

        candidate.update!(status: "matched", subject_type: "Organization", subject_id: record.id, proposed_subject: false,
          notes: "Data Quality: same as #{record.name}. #{reason}")
        return if row["add_alias"] || record.verification_status != "verified"

        # Only another way of naming it: its source is added, nothing changes.
        rest = candidate.payload.to_h.except("name", "aliases")
        return unless rest.empty? || DataQuality::Differences.changes(candidate, record, directory:)&.empty?

        in_source = ->(quote) { candidate.source.content_text.to_s.include?(quote.to_s) }
        confirmation = directory.confirm(candidate, in_source:, add_evidence: true)
        if confirmation&.confirmed?
          candidate.update!(status: "confirmed", notes: "Data Quality: same as #{record.name}; adds the source. #{reason}")
        end
        nil
      end

      def propose(candidate, reason, directory, created)
        payload = candidate.payload.to_h
        attributes = payload.slice(*%w[name hq_city hq_state description website]).symbolize_keys
        result = directory.write_pending("organization", attributes, candidate:, crawl_run: candidate.crawl_run || CrawlRun.new(id: nil))
        return "couldn't propose it: #{result.errors.to_sentence}" unless result.success?
        return "#{payload['name'].inspect} already exists (##{result.ref.id}); use same_as" unless result.created

        created << { "type" => "Organization", "id" => result.ref.id }
        candidate.update!(status: "matched", subject_type: "Organization", subject_id: result.ref.id, proposed_subject: true,
          notes: "Data Quality: a new company. #{reason}")
        nil
      end

      def subsidiary_of(candidate, row, reason, directory, created)
        parent, error = target(row, directory)
        return error if error
        error = propose(candidate, reason, directory, created)
        return error if error

        child = created.last
        name = candidate.payload.to_h["name"]
        link = Candidate.create!(source: candidate.source, crawl_run: candidate.crawl_run, kind: "relationship", quote: candidate.quote, status: "new",
          payload: { "from_organization" => { "name" => name }, "to_organization" => { "name" => parent.name }, "relationship_type" => "subsidiary_of" })
        result = directory.write_pending("relationship", { from_organization_id: child["id"], to_organization_id: parent.id, relationship_type: "subsidiary_of" },
          candidate: link, crawl_run: candidate.crawl_run || CrawlRun.new(id: nil))
        return "couldn't propose the link: #{result.errors.to_sentence}" unless result.success?

        link.update!(status: "matched", subject_type: "Relationship", subject_id: result.ref.id, proposed_subject: true,
          notes: "Data Quality: #{name} is a subsidiary of #{parent.name}. #{reason}")
        created << { "type" => "Relationship", "id" => result.ref.id, "candidate_id" => link.id }
        nil
      end

      def close(candidate, reason, directory)
        candidate.update!(status: "rejected", reviewed_by: BY, reviewed_at: Time.current, notes: "Data Quality closed it: #{reason}")
        # A lead is never thrown away (#548).
        if DataQuality::Review.lead?(candidate) && (name = candidate.payload.to_h["name"]).present?
          directory.keep_lead(name:, key: "dq_close:#{candidate.id}", label: "Closed by Data Quality", url: candidate.source&.url)
        end
        nil
      end
  end
end
