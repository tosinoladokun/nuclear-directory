# Write side of the directory boundary: the one way facts get created or
# updated, by the seed loader and the data quality pipeline alike.
#
# Each call writes one fact together with its evidence and, optionally, a
# verification decision, then recomputes the fact's confidence. Input is
# plain hashes; ids for other records come from Directory::Lookup, and roles
# and technologies are named by key.
#
#   result = Directory::FactWriter.write(:organization_role,
#     { organization_id: ref.id, role: "reactor_vendor" },
#     evidence: [ { source_id: 7, quote: "…", found_by: "crawler", confidence: 0.8 } ],
#     verification: { status: "verified", by: "human:tosin" })
#   result.ok?      # => true
#   result.id       # => id of the organization_role
#   result.created  # => false when it already existed and was updated
#
# Writes are idempotent: an existing fact is found by its natural key (see
# KINDS) and updated, and evidence is matched by source and quote. A failed
# write changes nothing and returns errors instead of raising.
module Directory
  class FactWriter
    # conflicts: { "state" => [stored, incoming] } when a write disagreed with a
    # human-reviewed fact (see protect_human_verified); nothing was written.
    Result = Data.define(:kind, :id, :created, :errors, :conflicts) do
      def initialize(kind:, id:, created:, errors:, conflicts: {}) = super
      def ok? = errors.empty? && conflicts.empty?
      def conflict? = conflicts.any?
    end

    # Raised inside a write to undo it and report the disagreement.
    class Conflict < StandardError
      attr_reader :id, :conflicts

      def initialize(id, conflicts)
        @id = id
        @conflicts = conflicts
        super(conflicts.map { |name, (stored, incoming)| "human-verified #{name} is #{stored}; this source says #{incoming}" }.join("; "))
      end
    end

    # Never compared for conflicts: names vary by legal form and spelling
    # (aliases cover that), and slugs are internal.
    NOT_COMPARED = %i[name slug].freeze

    class Invalid < StandardError; end

    # attributes: what callers may set. Natural keys are how an existing
    # fact is found, so the same input never creates a second row.
    KINDS = {
      organization: {
        model: Organization,
        attributes: %i[name slug legal_name website domain description hq_city hq_state country_code founded_year status aliases]
      },
      organization_role: { model: OrganizationRole, attributes: %i[organization_id role] },
      organization_technology: { model: OrganizationTechnology, attributes: %i[organization_id technology] },
      facility: {
        model: Facility,
        attributes: %i[name slug parent_id facility_type status technology reactor_type capacity_mw nrc_docket
          eia_plant_id city state country_code latitude longitude aliases]
      },
      relationship: {
        model: Relationship,
        attributes: %i[from_organization_id to_organization_id relationship_type description started_on ended_on]
      },
      facility_relationship: {
        model: FacilityRelationship,
        attributes: %i[organization_id facility_id relationship_type ownership_pct description started_on ended_on]
      }
    }.freeze

    EVIDENCE_ATTRIBUTES = %i[source_id quote found_by confidence crawl_run_id].freeze

    def self.write(...) = new.write(...)

    # Runs the block while holding a lock on the fact, unless a human has
    # closed it (rejected or unpublished): then the block doesn't run and the
    # fact's Directory::FactStateRef is returned. nil otherwise. For callers
    # that act on a fact staying open, e.g. rejecting a candidate attached to
    # it, so a human's decision made meanwhile is never missed.
    def self.while_open(type:, id:)
      raise ArgumentError, "not a fact type: #{type.inspect}" unless Lookup::FACT_TYPES.include?(type.to_s)

      ActiveRecord::Base.transaction(requires_new: true) do
        record = type.to_s.constantize.lock.find_by(id:)
        next Lookup.fact_state(type:, id:) if record&.closed?

        yield
        nil
      end
    end
    def self.merge_organization(...) = new.merge_organization(...)

    # Merges one organization into another (one company per brand, decision
    # #23): a human's decision, so by: must start with "human:". In one
    # transaction that locks both, everything about from moves to into:
    # aliases (its name among them, so it still finds into), domain if into
    # has none, roles, technologies, plant links, company links, evidence and
    # the candidates attached to it. A fact into already has (or a link that
    # would point at itself, such as "Urenco USA subsidiary of Urenco") stays
    # on from and is rejected, and a closed fact stays where it was decided
    # (#229). Then from is unpublished, and the audit reason
    # says where it went and what moved. Returns a Result for into.
    def merge_organization(from_id:, into_id:, by:, reason: nil)
      raise Invalid, "a merge is a human's decision (by: \"human:…\")" unless by.to_s.start_with?("human:")
      raise Invalid, "can't merge an organization into itself" if from_id == into_id

      moved = Hash.new(0)
      ActiveRecord::Base.transaction(requires_new: true) do
        records = Organization.lock.where(id: [ from_id, into_id ]).order(:id).index_by(&:id)
        from = records[from_id] or raise Invalid, "no organization with id #{from_id}"
        into = records[into_id] or raise Invalid, "no organization with id #{into_id}"
        raise Invalid, "#{into.name} is #{into.verification_status}; merge into a live organization" if into.closed?
        raise Invalid, "#{from.name} is already #{from.verification_status}" if from.closed?

        from.aliases.each do |row|
          if into.aliases.exists?(normalized_alias: row.normalized_alias) then row.destroy!
          else row.update!(organization: into) && moved["aliases"] += 1
          end
        end
        # Its own name too, as merge_facility does (DATA.md D1: every spelling
        # is an alias), so a source still using it ("BWXT NOG TECHNOLOGIES")
        # finds into. Not when it's into's name, an alias already, or
        # another company's name.
        name = OrganizationAlias.normalize(from.name)
        others = Organization.where.not(id: [ from.id, into.id ]).pluck(:name).map { |other| OrganizationAlias.normalize(other) }
        unless name == OrganizationAlias.normalize(into.name) || OrganizationAlias.exists?(normalized_alias: name) || others.include?(name)
          into.aliases.create!(alias: from.name) && moved["aliases"] += 1
        end
        if (domain = from.domain)
          from.update_columns(domain: nil)
          into.update!(domain:) && moved["domain"] += 1 if into.domain.blank?
        end
        retired = []
        { organization_roles: :role_id, organization_technologies: :technology_id,
          facility_relationships: %i[facility_id relationship_type] }.each do |table, key|
          from.public_send(table).each do |row|
            next if row.closed? # rejected or taken down: it stays where it was decided (#229)

            same = into.public_send(table).where(Array(key).index_with { |column| row.public_send(column) })
            next retired << row if same.exists?

            row.update!(organization: into) && moved[table.to_s] += 1
          end
        end
        Relationship.where(from_organization_id: from.id).or(Relationship.where(to_organization_id: from.id)).each do |row|
          next if row.closed?

          ends = { from_organization_id: row.from_organization_id, to_organization_id: row.to_organization_id }
            .transform_values { |id| id == from.id ? into.id : id }
          duplicate = Relationship.where(**ends, relationship_type: row.relationship_type).where.not(id: row.id).exists?
          next retired << row if ends.values.uniq.size == 1 || duplicate

          row.update!(ends) && moved["relationships"] += 1
        end
        Evidence.where(subject: from).each do |row|
          duplicate = Evidence.where(subject: into, source_id: row.source_id, quote: row.quote).exists?
          duplicate ? row.destroy! : row.update!(subject: into) && moved["evidence"] += 1
        end
        moved["candidates"] = Candidate.where(subject_type: "Organization", subject_id: from.id).update_all(subject_id: into.id, proposed_subject: false) # they didn't propose into

        note = "Merged into #{into.name} (##{into.id})"
        retired.each { |row| row.reject!(by:, reason: "#{note}; #{into.name} already has this, or it would point at itself") unless row.closed? }
        summary = moved.select { |_, count| count.positive? }.map { |what, count| "#{count} #{what.tr('_', ' ').then { |label| count == 1 ? label.singularize : label }}" }
        from.unpublish!(by:, reason: [ reason, "#{note}. Moved: #{summary.join(', ').presence || 'nothing'}" ].compact.join(". "),
          context: { "merged_into" => { "type" => into.class.name, "id" => into.id } }) # for the admin's exits (#166)
        # Its address, and any it kept from earlier renames or merges, now
        # lead straight to into's page (#143).
        FormerSlug.where(sluggable: from).find_each { |former| into.remember_slug(former.slug) }
        into.remember_slug(from.slug)
        into.recompute_confidence!
      end
      Result.new(kind: :organization, id: into_id, created: false, errors: [])
    rescue Invalid, ActiveRecord::RecordInvalid => error
      failure(:organization, error.message)
    end

    def self.merge_facility(...) = new.merge_facility(...)

    # Site fields a merge copies to into when into has none.
    SITE_FIELDS = %i[eia_plant_id facility_type status technology_id reactor_type capacity_mw city state latitude longitude].freeze

    # Merges one site into another (one page per plant, #229), the
    # counterpart of merge_organization: a human's decision, in one
    # transaction that locks both. into gets from's blank-on-into fields (its
    # EIA plant ID first, cleared on from so the unique index holds), its
    # units, its aliases and its name as an alias, its company links,
    # evidence and the candidates attached to it. A link into already has
    # stays on from and is rejected, and a closed link stays where it was
    # decided; values into already has are kept, and filled ones are on
    # into's history. Two sites with different EIA plant IDs are two plants
    # and aren't merged. Then
    # from is unpublished with where it went and what moved, and its address
    # leads to into (#143). Sites only: a unit is merged by moving it.
    def merge_facility(from_id:, into_id:, by:, reason: nil)
      raise Invalid, "a merge is a human's decision (by: \"human:…\")" unless by.to_s.match?(/\Ahuman:\S+\z/)
      raise Invalid, "can't merge a plant into itself" if from_id == into_id

      moved = Hash.new(0)
      ActiveRecord::Base.transaction(requires_new: true) do
        records = Facility.lock.where(id: [ from_id, into_id ]).order(:id).index_by(&:id)
        from = records[from_id] or raise Invalid, "no plant with id #{from_id}"
        into = records[into_id] or raise Invalid, "no plant with id #{into_id}"
        raise Invalid, "#{into.name} is #{into.verification_status}; merge into a live plant" if into.closed?
        raise Invalid, "#{from.name} is already #{from.verification_status}" if from.closed?
        # A docketed record is an NRC unit, even one not yet under a site.
        [ from, into ].each do |site|
          raise Invalid, "#{site.name} is a unit; only sites are merged" if site.parent_id || site.nrc_docket.present?
        end
        if from.eia_plant_id.present? && into.eia_plant_id.present? && from.eia_plant_id != into.eia_plant_id
          raise Invalid, "#{from.name} is EIA plant #{from.eia_plant_id} and #{into.name} is #{into.eia_plant_id}: two plants, not one"
        end

        note = "Merged into #{into.name} (##{into.id})"
        filled = SITE_FIELDS.select { |name| into.public_send(name).blank? && from.public_send(name).present? }
        values = filled.index_with { |name| from.public_send(name) }
        before = filled.index_with { |name| into.public_send(name) } # blank, but "" isn't nil
        from.update_columns(eia_plant_id: nil) if values.key?(:eia_plant_id)
        if filled.any?
          into.update!(values)
          # On into's own history too, with where the values came from.
          into.verification_reason = "#{from.name} (##{from.id}) merged in: its #{filled.join(', ')}"
          into.audited_changes = values.to_h { |name, value| [ name.to_s, [ before[name], value ] ] }
          into.log_verification_event(from_status: into.verification_status, by:)
        end

        moved["units"] = from.children.update_all(parent_id: into.id, updated_at: Time.current)
        # Names as #89 has them: locked, and never another facility's name.
        # from's own name is the one exception: from is unpublished, and its
        # name now leads to into.
        names = [ *from.aliases.map(&:alias), from.name ]
        lock_facility_names(names)
        others = Facility.where.not(id: [ from.id, into.id ]).pluck(:name).map { |other| FacilityAlias.normalize(other) }.to_set
        from.aliases.destroy_all
        names.each do |name|
          normalized = FacilityAlias.normalize(name)
          next if normalized == FacilityAlias.normalize(into.name) || FacilityAlias.exists?(normalized_alias: normalized)
          next if others.include?(normalized)

          into.aliases.create!(alias: name) && moved["aliases"] += 1
        end
        retired = []
        from.facility_relationships.each do |row|
          next if row.closed? # a link someone rejected or took down stays where it was decided
          next retired << row if into.facility_relationships.exists?(organization_id: row.organization_id, relationship_type: row.relationship_type)

          row.update!(facility: into) && moved["facility_relationships"] += 1
        end
        Evidence.where(subject: from).each do |row|
          duplicate = Evidence.where(subject: into, source_id: row.source_id, quote: row.quote).exists?
          duplicate ? row.destroy! : row.update!(subject: into) && moved["evidence"] += 1
        end
        moved["candidates"] = Candidate.where(subject_type: "Facility", subject_id: from.id).update_all(subject_id: into.id, proposed_subject: false) # they didn't propose into

        retired.each { |row| row.reject!(by:, reason: "#{note}; #{into.name} already has this link") unless row.closed? }
        summary = moved.select { |_, count| count.positive? }.map { |what, count| "#{count} #{what.tr('_', ' ').then { |label| count == 1 ? label.singularize : label }}" }
        summary << filled.join(", ") if filled.any?
        from.unpublish!(by:, reason: [ reason, "#{note}. Moved: #{summary.join(', ').presence || 'nothing'}" ].compact.join(". "),
          context: { "merged_into" => { "type" => into.class.name, "id" => into.id } }) # for the admin's exits (#166)
        FormerSlug.where(sluggable: from).find_each { |former| into.remember_slug(former.slug) }
        into.remember_slug(from.slug)
        into.recompute_confidence!
        # Units and links moved without saving into: its public snapshot
        # expires on commit all the same (Verifiable).
        into.touch
      end
      Result.new(kind: :facility, id: into_id, created: false, errors: [])
    rescue Invalid, ActiveRecord::RecordInvalid => error
      failure(:facility, error.message)
    end

    def self.remove_evidence(...) = new.remove_evidence(...)

    # Removes one piece of evidence from a fact, e.g. a quote attached to the
    # wrong link (#226): a human's correction, so by: must start with "human:"
    # and a reason is required. The fact is locked first, like any write, and
    # a rejected or unpublished fact isn't changed. A published or verified
    # fact keeps at least one piece of evidence. The fact's history records what was
    # removed (changed_values "evidence" => ["<source url>: <quote>", nil]).
    # source_id: and quote: must be the row's, so a wrong id can't remove
    # the right evidence.
    def remove_evidence(type:, id:, evidence_id:, source_id:, quote:, by:, reason:)
      raise Invalid, "removing evidence is a human's decision (by: \"human:…\")" unless by.to_s.match?(/\Ahuman:\S+\z/)
      raise Invalid, "removing evidence needs a reason" if reason.blank?
      raise Invalid, "not a fact type: #{type.inspect}" unless Lookup::FACT_TYPES.include?(type.to_s)

      ActiveRecord::Base.transaction(requires_new: true) do
        record = type.to_s.constantize.lock.find_by(id:) or raise Invalid, "no #{type} with id #{id}"
        name = Lookup.fact_state(type: type.to_s, id:).name.upcase_first
        if record.closed?
          raise Invalid, "#{name} was #{record.verification_status} by #{record.verified_by || 'review'}; not changed"
        end
        row = Evidence.lock.find_by(id: evidence_id, subject: record) or
          raise Invalid, "evidence #{evidence_id} isn't on #{name}"
        # Compared exactly: "9oops" isn't source 9, and "" isn't a missing quote.
        unless row.source_id == source_id && row.quote == quote
          raise Invalid, "evidence #{evidence_id} on #{name} isn't the source and quote given; not removed"
        end
        # Public now (a pending site shows through a verified unit), or verified
        # and hidden only by its parent: either way it must stay sourced.
        public_or_verified = record.verified? || Lookup.published?(type: type.to_s, id:)
        if public_or_verified && !Evidence.where(subject: record).where.not(id: row.id).exists?
          raise Invalid, "#{name} is published or verified and this is its only evidence; not removed"
        end

        removed = [ row.source.url, row.quote ].compact_blank.join(": ")
        row.destroy!
        record.recompute_confidence!
        record.verification_reason = reason
        record.audited_changes = { "evidence" => [ removed, nil ] }
        record.log_verification_event(from_status: record.verification_status, by:)
        # A change to the fact like any other: its updated_at moves and, on
        # commit, the public snapshot expires (Verifiable).
        record.touch
      end
      Result.new(kind: type.to_s.underscore.to_sym, id:, created: false, errors: [])
    rescue Invalid, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => error
      failure(type.to_s.underscore.to_sym, error.message)
    end

    # What #confirm found. outcome:
    # - :confirmed  every stated value is the fact's, and the source's evidence
    #               on it was stamped
    # - :different  differences: { "status" => [stored, stated] }
    # - :unsourced  the same values, but the fact has no evidence from this
    #               source yet (approving it would add the source)
    # - :missing    no such fact
    # overruled: values the source still states that a human replaced
    # ({ "state" => [stored, stated] }); the human's decision stands, so they
    # aren't differences. errors: why the attributes couldn't be compared.
    Confirmation = Data.define(:outcome, :differences, :overruled, :errors) do
      def initialize(outcome:, differences: {}, overruled: {}, errors: []) = super
      def confirmed? = outcome == :confirmed
    end

    def self.confirm(...) = new.confirm(...)

    # Whether a source still says what a fact records (#240), the check a
    # nightly crawl makes instead of queueing the same fact for review again.
    # attributes: what the source states, as for #write, with id: the fact;
    # a link's ends as ids (organization_id, facility_id…), which must be the
    # link's own (a unit stands for its site's link). quote: the source's row
    # as it reads now. in_source: optional, whether the source still contains
    # a quote; given, only evidence it accepts is stamped (this claim's quote
    # included), else only evidence with this quote.
    # Each stated value is compared as the model stores it (normalized, a
    # decimal at its column's scale: EIA's 1227.4000000000001 is 1227.40); a
    # value the source doesn't state isn't a difference. Names aren't
    # compared, as verify doesn't compare them: spelling variants are
    # expected, and which fact it is was settled by its docket, plant ID,
    # domain or an alias (a link: by its ends). The fact's decision doesn't
    # matter: a rejected or unpublished fact confirmed this way stays as
    # decided. When confirmed, the evidence from source_id gets
    # last_confirmed_at and the rows' hash; nothing else changes and nothing
    # is audited, so a fact's history doesn't fill with nightly checks.
    def confirm(kind, attributes, source_id:, quote:, in_source: nil, rows_sha256: nil, at: Time.current)
      kind = kind.to_sym
      spec = KINDS[kind] or return Confirmation.new(outcome: :missing, errors: [ "unknown kind #{kind.inspect}" ])
      attributes = attributes.to_h.symbolize_keys
      unknown = attributes.keys - spec[:attributes] - [ :id ]
      return Confirmation.new(outcome: :different, errors: [ "unknown attributes: #{unknown.join(', ')}" ]) if unknown.any?

      ActiveRecord::Base.transaction(requires_new: true) do
        record = spec[:model].lock.find_by(id: attributes[:id]) or next Confirmation.new(outcome: :missing)

        # A link is the same claim only between the same company and plant: a
        # claim attached to another plant's link (#226) is never confirmed.
        differences = different_ends(kind, record, attributes)
        overruled = {}
        model_attributes(kind, attributes).except(*NOT_COMPARED, *LINK_ENDS.fetch(kind, {}).keys).each do |name, stated|
          next if stated.blank?

          stored = record.public_send(name)
          next if stored.present? && same_stored_value?(record, name, stored, stated)

          pair = [ shown(stored), shown(stated) ]
          overruled_by_human?(record, name, stated) ? overruled[name.to_s] = pair : differences[name.to_s] = pair
        end
        next Confirmation.new(outcome: :different, differences:, overruled:) if differences.any?

        # Only quotes the source still contains are re-checked: this claim's,
        # or another of this fact's it still has (a company quoted from another
        # of its rows). A quote it no longer contains isn't; with none, a
        # person approves and the current quote is added.
        still_there = in_source || ->(text) { text == quote }
        current = Evidence.where(subject: record, source_id:).select { |row| still_there.call(row.quote) }
        next Confirmation.new(outcome: :unsourced, overruled:) if current.empty?

        Evidence.where(id: current.map(&:id)).update_all(last_confirmed_at: at, confirmed_sha256: rows_sha256)
        Confirmation.new(outcome: :confirmed, overruled:)
      end
    rescue Invalid => e
      Confirmation.new(outcome: :different, errors: [ e.message ])
    end

    def self.reconfirm_source(...) = new.reconfirm_source(...)

    # A source read again whose rows haven't changed (#240). Stamps only the
    # evidence its current rows still support: on facts (pairs of type and
    # id) a person approved or the pipeline confirmed from those rows, and
    # with one of their quotes. A fact the rows dropped, or one they
    # contradict, isn't stamped. Returns how many rows were stamped.
    def reconfirm_source(source_id:, facts:, quotes:, rows_sha256:, at: Time.current)
      by_type = Array(facts).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      return 0 if by_type.empty? || Array(quotes).empty?

      supported = by_type.map { |type, ids| Evidence.where(subject_type: type, subject_id: ids) }.reduce(:or)
      Evidence.where(source_id:, quote: quotes).and(supported).update_all(last_confirmed_at: at, confirmed_sha256: rows_sha256)
    end

    def self.existing(...) = new.existing(...)

    # The id of the fact these attributes name (a link by its ends and type,
    # a record by its keys), or nil. Reads only; finds closed facts too.
    def existing(kind, attributes)
      kind = kind.to_sym
      spec = KINDS[kind] or return
      find(kind, spec[:model], attributes.to_h.symbolize_keys)&.id
    rescue Invalid
      nil
    end

    def self.fill_site_from_unit(...) = new.fill_site_from_unit(...)

    # Fills a site's blank fields (from fields:) with its unit's stored
    # values, with evidence, in one transaction that locks the unit and then
    # the site. Only a verified unit speaks for its site, and only for fields
    # still blank once both are locked, so a decision or a fill made
    # meanwhile is seen. A protected write: a rejected site isn't changed (an
    # error is returned), and when a human reviewed the site, a unit value
    # that disagrees with one the site has is reported as a conflict and
    # nothing is written. nil when there's nothing to fill.
    def fill_site_from_unit(unit_id, fields:, evidence:)
      ActiveRecord::Base.transaction(requires_new: true) do
        unit = Facility.lock.find_by(id: unit_id)
        next unless unit&.parent_id && unit.verified?

        site = Facility.lock.find(unit.parent_id)
        stated = fields.to_h { |name| [ name.to_sym, unit.public_send(name) ] }.compact_blank
        # A unit's status is its site's only when every other live unit there
        # has it too: Dresden 1 decommissioning doesn't make the station so
        # while Dresden 2 and 3 run (#312).
        if stated.key?(:status)
          others = Facility.where(parent_id: site.id).where.not(id: unit.id).where.not(verification_status: Verifiable::CLOSED_STATUSES).pluck(:status)
          stated.delete(:status) if others.any? { |status| status != stated[:status] }
        end
        if site.human_reviewed? && !site.closed? && (conflicts = conflicts_with(site, stated)).any?
          raise Conflict.new(site.id, conflicts)
        end
        values = stated.select { |name, _| site.public_send(name).blank? }
        next if values.empty?

        write(:facility, values.merge(id: site.id), fill_blank: true, protect_human_verified: true, evidence:)
      end
    rescue Conflict => e
      Result.new(kind: :facility, id: e.id, created: false, errors: [ e.message ], conflicts: e.conflicts)
    end

    # Many writes in one transaction (e.g. a bulk approve), each in its own
    # savepoint so one failure doesn't undo the others. writes: an array of
    # { kind:, attributes:, evidence:, verification:, protect_human_verified: }.
    # Returns one Result per write, in order. Each write is audited as usual.
    WRITE_KEYS = %i[kind attributes evidence verification fill_blank protect_human_verified].freeze

    # A misspelled key (say verfication:) fails that write rather than being
    # dropped, so a bulk approval never reports success for a fact it didn't
    # approve.
    def self.write_many(writes)
      ActiveRecord::Base.transaction do
        writes.map do |write|
          write = write.to_h.symbolize_keys
          unknown = write.keys - WRITE_KEYS
          next new.send(:failure, write[:kind], "unknown write keys: #{unknown.join(", ")}") if unknown.any?
          missing = %i[kind attributes].reject { |key| write[key].present? || write[key] == {} }
          next new.send(:failure, write[:kind], "missing write keys: #{missing.join(", ")}") if missing.any?
          unless write[:kind].respond_to?(:to_sym)
            next new.send(:failure, nil, "kind must be a name, not #{write[:kind].inspect}")
          end

          new.write(write.fetch(:kind), write.fetch(:attributes), **write.except(:kind, :attributes))
        end
      end
    end

    # kind: a key of KINDS. attributes may include :id to update a known row.
    # verification: { status: "pending" | "verified" | "rejected" | "unpublished",
    #   by: "human:tosin", reason: "optional, kept in the audit trail",
    #   context: { "candidate_id" => 12 } (optional, kept with the reason) }
    # remove_aliases: names to drop from an organization's aliases (never its
    # current name), audited with the write. Only with a human's verification.
    # fill_blank: true sets only attributes that are blank on an existing row,
    # so new data can complete a record without overwriting anything.
    # protect_human_verified: true treats a row a human has verified (or
    # rejected) as curated, so a human's decision is never overwritten:
    # - a rejected or unpublished row isn't changed at all (an error is returned)
    # - if an incoming value disagrees with a stored one, nothing is written
    #   (no attributes, evidence or confidence change) and the result's
    #   conflicts say what disagreed, for review
    # - otherwise only blank attributes are filled, evidence is added, and the
    #   verification is left alone
    # Automated writers pass this.
    def write(kind, attributes, evidence: [], verification: nil, fill_blank: false, protect_human_verified: false,
      remove_aliases: [])
      kind = kind.to_sym
      spec = KINDS[kind] or return failure(kind, "unknown kind #{kind.inspect}")
      human = verification.to_h.symbolize_keys[:by].to_s.start_with?("human:")
      if Array(remove_aliases).any? && (kind != :organization || !human)
        return failure(kind, "remove_aliases: is only for an organization, with a human's verification")
      end
      attributes = attributes.to_h.symbolize_keys
      unknown = attributes.keys - spec[:attributes] - [ :id ]
      return failure(kind, "unknown attributes: #{unknown.join(", ")}") if unknown.any?
      # Candidate payloads reach here; a hash or number isn't a name.
      aliases = attributes[:aliases]
      unless aliases.nil? || aliases.is_a?(String) || (aliases.is_a?(Array) && aliases.all? { |name| name.nil? || name.is_a?(String) })
        return failure(kind, "aliases must be a name or a list of names")
      end

      record = nil
      created = false
      ActiveRecord::Base.transaction(requires_new: true) do
        # Checked before anything changes, even for a curated record whose
        # verification won't be applied: a bad key must never pass silently.
        check_verification!(verification) if verification
        record = find(kind, spec[:model], attributes) || spec[:model].new
        created = record.new_record?
        # Locked, so a human's decision made while this write runs is seen
        # before the checks below, and two decisions at once are recorded in
        # the order they happen.
        record.lock! unless created
        # A rejected or unpublished fact only changes by a human's hand:
        # protected writes never change it, and any other write must carry a
        # human's decision (verification: { by: "human:…" }), so the change is
        # audited and attributed.
        human_decision = verification.to_h.symbolize_keys[:by].to_s.start_with?("human:")
        if !created && record.closed? && (protect_human_verified || !human_decision)
          raise Invalid, "#{Lookup.fact_state(type: record.class.name, id: record.id).name.upcase_first} was " \
            "#{record.verification_status} by #{record.verified_by || 'review'}" \
            "#{" on #{record.verified_at.to_date}" if record.verified_at}; not changed"
        end
        # No automated unit under a rejected or unpublished site, whether the
        # write names the site or the unit already has one; the site is locked,
        # so a decision made while this write runs is seen.
        site_id = attributes.key?(:parent_id) ? attributes[:parent_id] : record.parent_id if kind == :facility
        if protect_human_verified && site_id && (site = Facility.lock.find_by(id: site_id))&.closed?
          raise Invalid, "site #{site.name} was #{site.verification_status} by #{site.verified_by || 'review'}; no units under it"
        end
        # Rejecting an existing link (no values, just the decision) needs no open
        # ends: retiring a proposal whose company was closed must still work.
        rejecting_only = !created && attributes.keys == [ :id ] && verification.to_h.symbolize_keys[:status].to_s == "rejected"
        check_link_ends(kind, attributes, record) if protect_human_verified && !rejecting_only
        curated = protect_human_verified && !created && record.human_reviewed?
        changes = model_attributes(kind, attributes)
        # A plant found by its docket, name or an alias keeps its name: writing
        # "Three Mile Island Unit 1" updates Crane, it doesn't rename it. Only a
        # write by id renames.
        changes.delete(:name) if kind == :facility && !created && !attributes.key?(:id)
        lock_facility_names([ changes[:name], *Array(attributes[:aliases]) ]) if kind == :facility
        check_facility_name(record, changes[:name]) if kind == :facility && changes[:name]
        if curated && (conflicts = conflicts_with(record, changes)).any?
          raise Conflict.new(record.id, conflicts)
        end
        changes = changes.select { |name, _| record.public_send(name).blank? } if (fill_blank || curated) && !created
        record.assign_attributes(changes)
        record.save!
        edited = audited_values(record) unless created

        if kind == :organization
          aliases_before = record.aliases.pluck(:alias).sort
          write_aliases(record, [ record.name, *attributes[:aliases] ])
          dropped = Array(remove_aliases).map { |name| OrganizationAlias.normalize(name) } - [ OrganizationAlias.normalize(record.name) ]
          record.aliases.where(normalized_alias: dropped).delete_all if dropped.any?
          aliases_after = record.aliases.reload.pluck(:alias).sort
          edited["aliases"] = [ aliases_before, aliases_after ] if edited && aliases_after != aliases_before
        end
        if kind == :facility
          aliases_before = record.aliases.pluck(:alias).sort
          # A name that was one of the plant's aliases is now its name.
          record.aliases.where(normalized_alias: FacilityAlias.normalize(record.name)).delete_all
          write_facility_aliases(record, attributes[:aliases])
          aliases_after = record.aliases.reload.pluck(:alias).sort
          edited["aliases"] = [ aliases_before, aliases_after ] if edited && aliases_after != aliases_before
        end
        Array(evidence).each { |item| write_evidence(record, item) }
        apply_verification(record, verification, edited:) if verification && !curated
        record.recompute_confidence!
      end

      Result.new(kind:, id: record.id, created:, errors: [])
    rescue Conflict => e
      Result.new(kind:, id: e.id, created: false, errors: [ e.message ], conflicts: e.conflicts)
    rescue Invalid, ArgumentError => e
      failure(kind, e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(kind, e.record.errors.full_messages.map { |m| "#{e.record.model_name.human}: #{m}" })
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::CheckViolation,
      ActiveRecord::NotNullViolation => e
      failure(kind, e.message.lines.first.strip)
    end

    private
      # Incoming values that differ from the stored ones, where both are
      # present: { "state" => ["NJ", "DE"] }. Websites compare by domain.
      def conflicts_with(record, changes)
        changes.each_with_object({}) do |(name, incoming), found|
          next if NOT_COMPARED.include?(name.to_sym)

          stored = record.public_send(name)
          next if incoming.blank? || stored.blank?
          next if same_value?(record, name, stored, incoming)

          found[name.to_s] = [ shown(stored), shown(incoming) ]
        end
      end

      def same_value?(record, name, stored, incoming)
        if name.to_sym == :website
          # Same site if the same domain; a URL with no readable domain only equals itself.
          domains = [ stored, incoming ].map { |url| Organization.domain_from(url) }
          return domains.all?(&:present?) ? domains.uniq.one? : stored.strip == incoming.strip
        end
        return stored == incoming if incoming.is_a?(ActiveRecord::Base)

        # Compared as the model would store it ("us" is "US" once normalized).
        incoming = record.class.normalize_value_for(name.to_sym, incoming)
        stored == record.class.type_for_attribute(name.to_s).cast(incoming)
      end

      # same_value?, with a decimal compared at its column's scale.
      def same_stored_value?(record, name, stored, stated)
        column = record.class.columns_hash[name.to_s]
        if column&.type == :decimal && column.scale && (number = BigDecimal(stated.to_s, exception: false))
          return stored == number.round(column.scale)
        end

        same_value?(record, name, stored, stated)
      end

      # A value a human replaced on this fact: an audited human decision whose
      # change to name had this value as its "before".
      def overruled_by_human?(record, name, stated)
        return false unless record.respond_to?(:verification_events)

        record.verification_events.where("by LIKE 'human:%'").where("changed_values ? :name", name: name.to_s).any? do |event|
          before = Array(event.changed_values[name.to_s]).first
          before.present? && same_stored_value?(record, name, record.class.type_for_attribute(name.to_s).cast(before), stated)
        end
      end

      # A link's ends the source names that aren't the link's own:
      # { "facility" => [stored, stated] }. Both must be stated (as ids, found
      # by the caller); a unit stands for its site. Not a link: {}.
      def different_ends(kind, record, attributes)
        LINK_ENDS.fetch(kind, {}).each_with_object({}) do |(key, model), found|
          stored = record.public_send(key)
          stated = attributes[key]
          next if stated.present? && stated.to_i == stored
          next if stated.present? && model == Facility && Facility.exists?(id: stated, parent_id: stored)

          label = ->(id) { id.present? ? model.find_by(id:)&.name || "##{id}" : "not in the directory" }
          found[key.to_s.delete_suffix("_id")] = [ label.call(stored), label.call(stated) ]
        end
      end

      def shown(value) = value.respond_to?(:key) ? value.key : value.to_s

      def failure(kind, errors)
        Result.new(kind:, id: nil, created: false, errors: Array(errors))
      end

      # Finds the existing row for this fact, or nil.
      def find(kind, model, attrs)
        return model.find_by(id: attrs[:id]) || raise(Invalid, "no #{kind} with id #{attrs[:id]}") if attrs[:id]

        # A link is found (or made) by its ends. Without one, find_by would
        # match any link of that type, and the write would land on the wrong
        # one (24 approvals on 12 Oct added quotes to unrelated "operates" links).
        missing = LINK_ENDS.fetch(kind, {}).keys.reject { |key| attrs[key].present? }
        raise Invalid, "a #{kind.to_s.tr('_', ' ')} needs both ends; missing #{missing.to_sentence}" if missing.any?
        # And its type: with both ends but no type, it would match any link between them.
        if %i[relationship facility_relationship].include?(kind) && attrs[:relationship_type].blank?
          raise Invalid, "a #{kind.to_s.tr('_', ' ')} needs a relationship type"
        end

        case kind
        when :organization
          ref = [ attrs[:name], *attrs[:aliases] ].compact.lazy.filter_map { |name| Lookup.organization(name:) }.first
          domain = attrs.key?(:domain) ? attrs[:domain] : Organization.domain_from(attrs[:website])
          ref ||= Lookup.organization(domain:) if domain.present?
          Organization.find(ref.id) if ref
        when :facility
          ref = Lookup.facility(nrc_docket: attrs[:nrc_docket]) if attrs[:nrc_docket].present?
          ref ||= Lookup.facility(eia_plant_id: attrs[:eia_plant_id]) if attrs[:eia_plant_id].present?
          # An EIA site is found among sites only, never as a same-name NRC unit.
          key = attrs[:eia_plant_id].present? && attrs[:nrc_docket].blank? ? :site_name : :name
          ref ||= [ attrs[:name], *attrs[:aliases] ].compact_blank.lazy.filter_map { |name| Lookup.facility(key => name) }.first
          Facility.find(ref.id) if ref
        when :organization_role
          model.find_by(organization_id: attrs[:organization_id], role: lookup_row(Role, attrs[:role]))
        when :organization_technology
          model.find_by(organization_id: attrs[:organization_id], technology: lookup_row(Technology, attrs[:technology]))
        when :relationship
          model.find_by(attrs.slice(:from_organization_id, :to_organization_id, :relationship_type))
        when :facility_relationship
          model.find_by(attrs.slice(:organization_id, :facility_id, :relationship_type))
        end
      end

      # Turns caller input into model attributes: role/technology keys become
      # records, an organization's domain defaults to its website's (pass
      # domain: nil to leave it blank), and :aliases is handled separately.
      def model_attributes(kind, attrs)
        attrs = attrs.except(:id, :aliases)
        attrs[:domain] = Organization.domain_from(attrs[:website]) if kind == :organization && attrs[:website] && !attrs.key?(:domain)
        attrs[:role] = lookup_row(Role, attrs[:role]) if attrs.key?(:role)
        attrs[:technology] = lookup_row(Technology, attrs[:technology]) if attrs.key?(:technology) && attrs[:technology]
        attrs
      end

      def lookup_row(model, key)
        model.find_by(key: key.to_s) || raise(Invalid, "unknown #{model.model_name.singular} #{key.inspect}")
      end

      # The organization's own name is stored as an alias too, so
      # Lookup.organization(name:) only ever has to check aliases.
      def write_aliases(organization, names)
        names.compact_blank.uniq.each do |name|
          normalized = OrganizationAlias.normalize(name)
          existing = OrganizationAlias.find_by(normalized_alias: normalized)
          if existing.nil?
            organization.aliases.create!(alias: name)
          elsif existing.organization_id != organization.id
            raise Invalid, "alias #{name.inspect} already belongs to #{existing.organization.name}"
          end
        end
      end

      # A facility's other names. Its own name isn't stored (facility names
      # aren't unique), so a name that is another facility's is an error, as
      # is an alias another facility already has.
      # A plant can't take a name that's another plant's alias: the alias
      # would still find the other plant under some spellings.
      # A plant's name and other plants' aliases must never be the same name.
      # The unique index covers aliases only, so a rename and an alias write
      # for one normalized name take the same lock (held until the
      # transaction ends) and check while holding it. Every name a write
      # touches is locked up front in sorted order, after the row lock, so
      # two writes can't each hold a name the other waits for.
      def lock_facility_names(names)
        names.compact_blank.map { |name| FacilityAlias.normalize(name) }.uniq.sort.each do |normalized|
          sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "facility-name:#{normalized}" ])
          ActiveRecord::Base.connection.execute(sql)
        end
      end

      def check_facility_name(facility, name)
        owner = FacilityAlias.find_by(normalized_alias: FacilityAlias.normalize(name))
        return if owner.nil? || owner.facility_id == facility.id

        raise Invalid, "name #{name.inspect} is an alias of #{owner.facility.name}"
      end

      def write_facility_aliases(facility, names)
        Array(names).compact_blank.uniq.each do |name|
          normalized = FacilityAlias.normalize(name)
          next if FacilityAlias.normalize(facility.name) == normalized

          existing = FacilityAlias.find_by(normalized_alias: normalized)
          raise Invalid, "alias #{name.inspect} already belongs to #{existing.facility.name}" if existing && existing.facility_id != facility.id
          next if existing

          # Compared normalized, as aliases are ("Peach-Bottom" is "Peach Bottom").
          named = Facility.where.not(id: facility.id).pluck(:name).find { |other| FacilityAlias.normalize(other) == normalized }
          raise Invalid, "alias #{name.inspect} is the name of another facility (#{named})" if named

          facility.aliases.create!(alias: name)
        end
      end

      def write_evidence(record, item)
        item = item.to_h.symbolize_keys
        unknown = item.keys - EVIDENCE_ATTRIBUTES
        raise Invalid, "unknown evidence attributes: #{unknown.join(", ")}" if unknown.any?

        row = record.evidence.find_or_initialize_by(source_id: item[:source_id], quote: item[:quote])
        row.assign_attributes(item.slice(:found_by, :confidence, :crawl_run_id))
        row.save!
      end

      # Re-applying the same decision leaves verified_at alone, so re-runs
      # don't look like fresh reviews.
      VERIFICATION_KEYS = %i[status by reason context].freeze

      # edited: attribute changes this write made, { "state" => [before, after] },
      # recorded on the audit event with the decision.
      def check_verification!(verification)
        verification = verification.to_h.symbolize_keys
        unknown = verification.keys - VERIFICATION_KEYS
        raise Invalid, "unknown verification keys: #{unknown.join(", ")}" if unknown.any?
        raise Invalid, "verification needs by: (who decided)" if verification[:by].blank?
      end

      def apply_verification(record, verification, edited: {})
        verification = verification.to_h.symbolize_keys
        status, by = verification.values_at(:status, :by)
        record.verification_reason = verification[:reason]
        record.verification_context = verification[:context]
        record.audited_changes = edited.presence
        record.decided_by = by

        if record.verification_status == status.to_s && record.verified_by == by
          # Same decision again: worth an event only when a human changed the
          # values or names its context (e.g. approving another candidate for
          # the same fact), so the history shows where it came from.
          if by.to_s.start_with?("human:") && (edited.present? || verification[:context].present?)
            record.log_verification_event(from_status: record.verification_status, by:)
          end
          return
        end

        record.update!(verification_status: status, verified_by: by, verified_at: status.to_s == "pending" ? nil : Time.current)
      end

      LINK_ENDS = {
        organization_role: { organization_id: Organization }, organization_technology: { organization_id: Organization },
        relationship: { from_organization_id: Organization, to_organization_id: Organization },
        facility_relationship: { organization_id: Organization, facility_id: Facility }
      }.freeze

      # An automated link write needs both ends open: each is locked and
      # checked, so a company or plant closed after match isn't linked to.
      # A unit end counts as closed when its site is. Rows are locked in one
      # fixed order (table, then id), so two links written at once in opposite
      # directions can't deadlock.
      def check_link_ends(kind, attributes, record)
        ends = LINK_ENDS.fetch(kind, {}).filter_map do |key, model|
          id = attributes.key?(key) ? attributes[key] : record.public_send(key)
          [ model, id ] if id
        end
        sites = ends.filter_map { |model, id| [ Facility, model.where(id:).pick(:parent_id) ] if model == Facility }.select(&:last)
        (ends + sites).uniq.sort_by { |model, id| [ model.table_name, id.to_i ] }.each do |model, id|
          finish = model.lock.find_by(id:) or next
          next unless finish.closed?

          raise Invalid, "#{finish.name} was #{finish.verification_status} by #{finish.verified_by || 'review'}; not linked"
        end
      end

      AUDIT_IGNORED = %w[created_at updated_at confidence verification_reason verification_context audited_changes].freeze

      def audited_values(record)
        record.saved_changes.except(*AUDIT_IGNORED).transform_values { |(before, after)| [ before, after ] }
      end
  end
end
