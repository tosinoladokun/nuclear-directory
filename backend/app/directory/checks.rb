# The tags Data Quality defined for the directory's records (#238): status,
# quality flags, coverage gaps, source and who decided. One definition for
# two uses: the admin's Live filters and counts (#201), and the coming
# data_quality:audit report, so the screen and the nightly report never
# disagree.
#
# Each tag has a key (for URLs and code), a label (the screen's words), a
# group, a severity (flags only, 1 = most urgent) and, per kind of record it
# applies to, a query: a relation of that model's matching records.
#
#   Directory::Checks.find("no-operator").ids(Facility)   # => [12, 40, …]
#   Directory::Checks.in_group("flags")                   # => [Tag, …] by severity
module Directory::Checks
  Tag = Data.define(:key, :label, :group, :severity, :hint, :queries) do
    def applies_to?(model) = queries.key?(model.name)

    # Ids of this model's records with the tag ([] where it doesn't apply).
    def ids(model) = applies_to?(model) ? queries.fetch(model.name).call.pluck(:id) : []
  end

  GROUPS = { "status" => "Status", "flags" => "Flags", "gaps" => "Gaps", "source" => "Source", "decided" => "Decided by" }.freeze
  # Status is one choice; the other groups are several (OR within a group, AND across).
  SINGLE = %w[status].freeze

  # NRC and EIA re-confirm nightly; a web page or hand research is checked far less often (#241).
  NIGHTLY_KINDS = %w[nrc_reactor_list nrc_power_status nrc_decommissioning eia_generators eia_860m_index].freeze
  STALE_DAYS = { nightly: 14, other: 365 }.freeze

  OPEN = %w[new matched needs_review].freeze
  FACT_MODELS = [ Organization, Facility, Relationship, FacilityRelationship ].freeze

  class << self
    def all = @all ||= build.freeze
    def find(key) = all.find { |tag| tag.key == key }
    def in_group(group) = all.select { |tag| tag.group == group }.sort_by { |tag| [ tag.severity || 99, all.index(tag) ] }

    private
      def build
        status_tags + flag_tags + gap_tags + source_tags + decided_tags
      end

      # The same query for every fact model.
      def each_model(&query) = FACT_MODELS.to_h { |model| [ model.name, -> { query.call(model) } ] }

      def evidence(model) = Evidence.where(subject_type: model.name)
      def open_claims(model) = Candidate.where(status: OPEN, subject_type: model.name)

      def status_tags
        merged = ->(model) { VerificationEvent.where(subject_type: model.name, to_status: "unpublished").where("context ? 'merged_into'").select(:subject_id) }
        [
          Tag.new("live", "Live", "status", nil, "Visitors see it", each_model { |model| model.published }),
          Tag.new("hidden", "Hidden", "status", nil, "Approved, but what it hangs on is down",
            each_model { |model| model.verified.where.not(id: model.published.select(:id)) }),
          Tag.new("pending", "Pending", "status", nil, "Waiting for a decision", each_model { |model| model.where(verification_status: "pending") }),
          Tag.new("rejected", "Rejected", "status", nil, "Removed by a decision", each_model { |model| model.where(verification_status: "rejected") }),
          Tag.new("unpublished", "Unpublished", "status", nil, "Taken off by a person", each_model { |model| model.where(verification_status: "unpublished") }),
          Tag.new("merged", "Merged", "status", nil, "Merged into another record",
            each_model { |model| model.where(verification_status: "unpublished", id: merged.call(model)) })
        ]
      end

      def flag_tags
        # A quote of only spaces or newlines is no quote.
        quoted = ->(model) { evidence(model).where("evidence.quote ~ '[^[:space:]]'").select(:subject_id) }
        fresh = lambda do |model|
          checked = "COALESCE(evidence.last_confirmed_at, evidence.created_at)"
          evidence(model).joins(:source).where(
            "(sources.source_kind IN (:nightly) AND #{checked} > :nightly_since) OR (sources.source_kind NOT IN (:nightly) AND #{checked} > :other_since)",
            nightly: NIGHTLY_KINDS, nightly_since: STALE_DAYS[:nightly].days.ago, other_since: STALE_DAYS[:other].days.ago
          ).select(:subject_id)
        end
        domains = ->(model) { evidence(model).joins(:source).group(:subject_id).having("COUNT(DISTINCT COALESCE(sources.domain, sources.url)) = 1").select(:subject_id) }
        # A source's latest reading of a fact that kept a person's overruling
        # value (#240: "a person's decision stands"), so it still disagrees.
        # Only each source's latest claim counts, so an old conflict since
        # settled doesn't linger.
        overruled = lambda do |model|
          latest = Candidate.where(subject_type: model.name).where.not(subject_id: nil)
            .select("DISTINCT ON (candidates.source_id, candidates.subject_id) candidates.id").order("candidates.source_id, candidates.subject_id, candidates.id DESC")
          Candidate.where(id: latest, status: "confirmed").where("candidates.notes ILIKE ?", "%a person's decision stands%").select(:subject_id)
        end
        [
          Tag.new("no-quote", "No quote", "flags", 1, "Live, with no quote",
            each_model { |model| model.published.where.not(id: quoted.call(model)) }),
          Tag.new("source-disagrees", "Source disagrees", "flags", 2, "A source says something else than a person decided",
            each_model { |model| model.where(id: open_claims(model).where("candidates.notes ILIKE 'human-verified %'").select(:subject_id)).or(model.where(id: overruled.call(model))) }),
          Tag.new("dropped-by-source", "Dropped by source", "flags", 3, "Its source no longer lists it",
            each_model { |model| model.where(id: open_claims(model).where(review_origin: "dropped").select(:subject_id)) }),
          Tag.new("stale", "Not re-checked", "flags", 4, "No source re-confirmed it in 14 days (NRC, EIA) or a year (web, research)",
            each_model { |model| model.where(id: evidence(model).select(:subject_id)).where.not(id: fresh.call(model)) }),
          Tag.new("single-source", "One source", "flags", 5, "Rests on one source",
            each_model { |model| model.where(id: domains.call(model)) }),
          Tag.new("in-review", "In review", "flags", 6, "A claim on it is waiting in Checks",
            each_model { |model| model.where(id: open_claims(model).select(:subject_id)) }),
          # The fact's own confidence, worked out from all its evidence (two
          # sources at 0.6 and 0.5 make 0.7), not any one source's.
          Tag.new("low-confidence", "Low confidence", "flags", 7, "Machine confidence under 0.7, not checked by a person",
            each_model do |model|
              model.where("#{model.table_name}.verified_by IS NULL OR #{model.table_name}.verified_by NOT LIKE 'human:%'")
                .where("#{model.table_name}.confidence < 0.7")
            end)
        ]
      end

      def gap_tags
        # Only links in effect today: an ended owner or operator, or one not
        # started yet, doesn't fill the gap, and successive owners aren't co-owners.
        current = -> { FacilityRelationship.published.where("facility_relationships.ended_on IS NULL OR facility_relationships.ended_on > :today", today: Date.current)
          .where("facility_relationships.started_on IS NULL OR facility_relationships.started_on <= :today", today: Date.current) }
        links = ->(type) { current.call.where(relationship_type: type) }
        # No live link of this type on the facility, its site or its units.
        without = lambda do |type|
          linked = links.call(type).select(:facility_id)
          Facility.where.not(id: linked).where("facilities.parent_id IS NULL OR facilities.parent_id NOT IN (?)", linked)
            .where.not(id: Facility.where(id: linked).where.not(parent_id: nil).select(:parent_id))
        end
        co_owned = -> { current.call.where(relationship_type: "owns").group(:facility_id).having("COUNT(*) >= 2").select(:facility_id) }
        [
          Tag.new("no-operator", "No operator", "gaps", nil, "An operating plant or reactor with no live operator",
            { "Facility" => -> { without.call("operates").operating } }),
          # Power plants only (DATA.md): a mine or enrichment plant is usually
          # owned by its operator and has no owns link, so it would sit here for good.
          Tag.new("no-owner", "No owner", "gaps", nil, "An operating power plant with no live owner",
            { "Facility" => -> { without.call("owns").operating.where(parent_id: nil, facility_type: "power_reactor") } }),
          Tag.new("no-capacity", "No capacity", "gaps", nil, "An operating reactor with no capacity",
            { "Facility" => -> { Facility.operating.where.not(nrc_docket: nil).where(capacity_mw: nil) } }),
          Tag.new("no-location", "No location", "gaps", nil, "A plant or reactor with no coordinates or state",
            { "Facility" => -> { Facility.where(latitude: nil).or(Facility.where(longitude: nil)).or(Facility.where(state: nil)) } }),
          Tag.new("no-site", "No site", "gaps", nil, "A docketed reactor not under a site",
            { "Facility" => -> { Facility.where.not(nrc_docket: nil).where(parent_id: nil) } }),
          Tag.new("no-category", "No category", "gaps", nil, "A company with no live role",
            { "Organization" => -> { Organization.where.not(id: OrganizationRole.published.select(:organization_id)) } }),
          Tag.new("no-links", "No links", "gaps", nil, "A company with no live plant link or deal",
            { "Organization" => lambda {
              Organization.where.not(id: FacilityRelationship.published.select(:organization_id))
                .where.not(id: Relationship.published.select(:from_organization_id)).where.not(id: Relationship.published.select(:to_organization_id))
            } }),
          Tag.new("no-share", "No share", "gaps", nil, "An owner of a co-owned plant with no ownership share",
            { "FacilityRelationship" => -> { FacilityRelationship.where(relationship_type: "owns", ownership_pct: nil, facility_id: co_owned.call) } })
        ]
      end

      def source_tags
        from_kinds = ->(kinds) { each_model { |model| model.where(id: evidence(model).joins(:source).where(sources: { source_kind: kinds }).select(:subject_id)) } }
        domains = ->(model) { evidence(model).joins(:source).group(:subject_id).having("COUNT(DISTINCT COALESCE(sources.domain, sources.url)) >= 2").select(:subject_id) }
        [
          Tag.new("nrc", "NRC", "source", nil, "Quoted from NRC", from_kinds.call(%w[nrc_reactor_list nrc_power_status nrc_decommissioning])),
          Tag.new("eia", "EIA", "source", nil, "Quoted from EIA-860M", from_kinds.call(%w[eia_generators])),
          Tag.new("doe", "USAspending", "source", nil, "Quoted from USAspending.gov", from_kinds.call(%w[usaspending_doe_awards])),
          Tag.new("web", "Web", "source", nil, "Quoted from a page the crawler found",
            each_model { |model| model.where(id: evidence(model).joins(:source).where(found_by: "crawler", sources: { source_kind: "web_page" }).select(:subject_id)) }),
          Tag.new("hand-research", "Research", "source", nil, "Quoted by a person",
            each_model { |model| model.where(id: evidence(model).where(found_by: "human").select(:subject_id)) }),
          Tag.new("multi-source", "2+ sources", "source", nil, "Two or more independent sources", each_model { |model| model.where(id: domains.call(model)) })
        ]
      end

      def decided_tags
        edited = ->(model) { VerificationEvent.where(subject_type: model.name).where("by LIKE 'human:%'").where("changed_values <> '{}'::jsonb").select(:subject_id) }
        [
          Tag.new("human-verified", "Person", "decided", nil, "A person approved it",
            each_model { |model| model.where("#{model.table_name}.verified_by LIKE 'human:%'") }),
          Tag.new("machine-verified", "Pipeline", "decided", nil, "Approved by the pipeline, not a person",
            each_model { |model| model.where("#{model.table_name}.verified_by LIKE 'agent:%'") }),
          Tag.new("human-edited", "Edited", "decided", nil, "A person changed a value", each_model { |model| model.where(id: edited.call(model)) })
        ]
      end
  end
end
