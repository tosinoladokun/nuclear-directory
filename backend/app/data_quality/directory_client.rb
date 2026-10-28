# The module's only door into the directory. Reads go through
# Directory::Lookup, writes through Directory::FactWriter (contract in
# app/directory/README.md); nothing else in DataQuality may reference
# directory code or models (enforced by test/data_quality/boundary_test.rb).
#
# Keeping the calls in one file means that if the directory interfaces
# change, or the module moves to its own service and talks to the
# directory over an API, only this file changes.
class DataQuality::DirectoryClient
  # A pointer to a directory record, e.g. Ref.new(type: "Organization", id: 12).
  # type is what candidates store in subject_type.
  Ref = Data.define(:type, :id)
  # What a lookup found: enough to match on and to explain a match.
  # values: a link's stored values ({ "ownership_pct" => 45.7, ... }), else nil.
  Record = Data.define(:type, :id, :name, :domain, :sec_cik, :eia_utility_id, :nrc_docket, :eia_plant_id, :parent_id, :facility_type, :status, :city, :state,
    :country_code, :verification_status, :verified_by, :verified_at, :values) do
    def ref = Ref.new(type:, id:)
    def rejected? = verification_status == "rejected"
    def unpublished? = verification_status == "unpublished"
    # Rejected or unpublished: a decision the pipeline never reopens on its own.
    def closed? = rejected? || unpublished?
    def decision = "#{verification_status} by #{verified_by || 'review'}#{" on #{verified_at.to_date}" if verified_at}"
  end
  # conflicts: { "state" => [stored, incoming] } when the write disagreed with
  # a human-verified fact; nothing was written, and ref points at that fact.
  WriteResult = Data.define(:ref, :errors, :created, :conflicts) do
    def initialize(ref:, errors:, created: false, conflicts: {}) = super
    def success? = errors.empty? && conflicts.empty?
    def conflict? = conflicts.any?
  end

  # A plant's status change (#316): plan is Directory::StatusChange's Plan
  # (changes, unchanged, operating_before, operating_after), or error says
  # why it can't be made.
  StatusResult = Data.define(:plan, :error) do
    def ok? = error.nil?
  end

  # Kinds whose payload names other records instead of carrying attributes;
  # the match stage resolves those names to ids and writes the fact.
  # Kinds that name other records (match resolves their ends). A deal term's
  # one end is the company or link it belongs to (#397).
  LINK_KINDS = %w[organization_role organization_technology relationship facility_relationship deal_term].freeze
  LINK_ENDS = %w[organization facility from_organization to_organization].freeze
  # Never taken from a payload: which record, which ends, and the slug.
  PAYLOAD_LOCKED = %w[id slug organization_id facility_id from_organization_id to_organization_id link_id].freeze

  def initialize(lookup: nil, fact_writer: nil)
    @owner_hints = []
    @lookup = lookup
    @fact_writer = fact_writer
  end

  # A CIK as the directory stores it, so two spellings compare equal.
  def normalize_cik(value) = lookup.cik(value)
  def normalize_eia_utility_id(value) = lookup.eia_utility_id(value)

  # Exact lookups. Pass one keyword; returns a Record or nil.
  # Enrich (#479): companies waiting for their pages to be read, and marking one read.
  def enrich_queue(limit: 5) = lookup.enrich_queue(limit:)
  def request_gap_fill(limit: 10) = lookup.request_gap_fill(limit:)
  def mark_enriched(id, requested_at) = lookup.mark_enriched(id, requested_at)
  def company_fact_choices = lookup.company_fact_choices

  def organization(name: nil, domain: nil, sec_cik: nil, eia_utility_id: nil)
    record("Organization", lookup.organization(name:, domain:, sec_cik:, eia_utility_id:))
  end

  # Companies with an SEC CIK, live ones only (#129): [SecFilerRef].
  def organizations_with_sec_cik = lookup.organizations_with_sec_cik

  # Published companies with a website: [[name, website]].
  def organizations_with_website = lookup.organizations_with_website

  def facility(id: nil, name: nil, site_name: nil, nrc_docket: nil, eia_plant_id: nil)
    record("Facility", lookup.facility(id:, name:, site_name:, nrc_docket:, eia_plant_id:))
  end

  # For a plant-level EIA file (#319): the power plants that have no EIA
  # plant ID yet, to find by name and state.
  def plants_without_eia_plant_id = lookup.plants_without_eia_plant_id
  def normalize_facility_name(name) = lookup.normalize_facility_name(name)

  # Runs the block with the candidate's attached fact locked, unless it was
  # rejected or unpublished meanwhile: then returns that fact's Record and
  # doesn't run the block. A candidate with no fact just runs the block.
  def unless_closed(candidate, &)
    return yield.then { nil } unless candidate.subject_id

    record(candidate.subject_type, fact_writer.while_open(type: candidate.subject_type, id: candidate.subject_id, &))
  end

  # The fact a candidate is attached to (any kind, links included), with its
  # current decision, or nil when it has none, with the values verify and the
  # admin compare (a link's in `values`).
  def attached_record(candidate)
    return unless candidate.subject_id

    case candidate.subject_type
    when "Organization" then record("Organization", lookup.organization(id: candidate.subject_id))
    when "Facility" then record("Facility", lookup.facility(id: candidate.subject_id))
    else fact(type: candidate.subject_type, id: candidate.subject_id)
    end
  end

  # Likely duplicates an exact lookup misses. Returns Records.
  def similar_organizations(name)
    lookup.similar_organizations(name).map { |ref| record("Organization", ref) }
  end

  # Organizations that are the same brand as name (legal-entity variants).
  def same_brand_organizations(name)
    lookup.same_brand_organizations(name, plants: plant_names).map { |ref| record("Organization", ref) }
  end

  # Company names coming up in this run, so the brand rule treats them as
  # owners from the start, whatever order the candidates are matched in.
  attr_reader :owner_hints

  def owner_hints=(names)
    @owner_hints = Array(names).compact_blank.uniq
    @plant_names = nil
  end

  # The brand a per-plant or regional company name stands for
  # ("NextEra Energy Seabrook, LLC" => "NextEra Energy"), or nil.
  def brand_name(name) = lookup.brand_name(name, plants: plant_names)

  # The brand a name reduces to ("NextEra Energy Seabrook, LLC" => "nextera"), or nil.
  def brand_key(name) = lookup.brand_key(name, plants: plant_names)

  def similar_facilities(name)
    lookup.similar_facilities(name).map { |ref| record("Facility", ref) }
  end

  # NRC units whose names fit name: in a state, or (state: nil) anywhere,
  # by a stricter rule. Returns Records.
  def facility_units(name:, state: nil)
    lookup.facility_units(name:, state:).map { |ref| record("Facility", ref) }
  end

  # Writes a fact the match stage found or proposed, with the candidate's
  # source as evidence (found_by: crawler). Verification is left alone, so a
  # new fact starts pending and an existing one keeps its status. A fact a
  # human has verified only gets its blanks filled; one a human rejected or
  # unpublished isn't changed (the result has an error).
  # evidence: false writes only the record (a link that may already exist
  # gets its evidence on publish, so nothing unverified lands on it early).
  # verification: a pending decision to record (Data Quality's agent, #548).
  def write_pending(kind, attributes, candidate:, crawl_run:, evidence: true, verification: nil)
    items = evidence ? [ { source_id: candidate.source_id, quote: candidate.quote, found_by: "crawler", crawl_run_id: crawl_run.id } ] : []
    result = fact_writer.write(kind, attributes, protect_human_verified: true, evidence: items, verification:)
    write_result(result)
  end

  # Writes a candidate as a verified fact, with the source it came from as
  # evidence. A matched candidate updates its record (attributes id:); for
  # link kinds the ends were resolved by match, so the rest of the payload is
  # sent. A fact a human has verified is never overwritten: only its blank
  # attributes are filled and its verification stays. A fact a human rejected
  # or unpublished isn't changed at all; the result has an error instead (FactWriter
  # protect_human_verified). Returns a WriteResult; never raises on
  # validation problems.
  #
  # by: a human ("human:tosin") approving it in the admin
  # (DataQuality::Review). A human is the authority, so their write isn't
  # protected: it applies the candidate's values even over a human-verified
  # fact, and records the candidate and run in the audit trail. Without by:,
  # it's the automated writer described above.
  #
  # An enrichment candidate (see enrichment?) sets only its values and leaves
  # the record's verification alone, since it doesn't vouch for the record
  # itself; even when a human approves it, it doesn't overwrite a
  # human-verified value (that comes back as a conflict).
  def write_fact(candidate, confidence:, crawl_run:, by: nil, reason: nil, edited: false)
    # The record written is the one match attached, never an id, a link end or
    # a slug in the payload (payloads aren't validated; Review locks these too).
    attributes = candidate.payload.except(*WRITE_SKIPPED).symbolize_keys
    attributes[:id] = candidate.subject_id if candidate.subject_id
    # A deal term's link verb only finds its link; the term has no such field.
    attributes.delete(:relationship_type) if candidate.kind == "deal_term"
    if candidate.kind == "organization"
      # The name it was found under becomes an alias only once a verdict accepts
      # it, and a matched company keeps its own name.
      attributes[:aliases] = [ *attributes[:aliases], attributes[:name] ].compact_blank.uniq
      attributes.delete(:name) if candidate.subject_id
    end
    # A matched plant keeps its own name too: a candidate found under one of its
    # aliases ("Three Mile Island Unit 1") mustn't rename Crane.
    attributes.delete(:name) if candidate.kind == "facility" && candidate.subject_id
    enrichment = enrichment?(candidate)
    verification =
      if enrichment then nil
      elsif by
        # edited: whether a person changed the values first, which makes
        # them the person's (Differences.written_by_person).
        context = { "candidate_id" => candidate.id, "crawl_run_id" => crawl_run&.id, "edited" => edited }
        { status: "verified", by:, reason:, context: }.compact
      else
        { status: "verified", by: "agent:verifier/#{crawl_run&.model || 'unknown'}" }
      end
    evidence = [ { source_id: candidate.source_id, quote: candidate.quote, found_by: "crawler", confidence:, crawl_run_id: crawl_run&.id } ]
    return write_alias(candidate, verification:, evidence:, by:) if candidate.kind == "organization_alias"
    return write_news(candidate, verification:, evidence:, by:) if candidate.kind == "news_item"

    result = fact_writer.write(candidate.kind, attributes, evidence:, verification:,
      protect_human_verified: by.nil? || enrichment)
    # One site per plant (#73): an enriched unit without a site goes under
    # the site for its EIA plant.
    group_unit(candidate) if result.ok? && enrichment && candidate.kind == "facility"
    write_result(result)
  end

  # Puts the NRC unit an enrichment candidate enriched under the site for
  # its EIA plant. Runs when the enrichment is published, and once for
  # enrichments published before #73. Returns nil when there's nothing to do:
  # the unit already has a site, or there's no live site for the plant. The
  # parent is filled only if it's still blank once the unit is locked, so a
  # site assigned meanwhile is never replaced.
  def group_unit(candidate)
    site_id = site_for_unit(candidate) or return
    write_result(fact_writer.write(:facility, { id: candidate.subject_id, parent_id: site_id }, fill_blank: true))
  end

  # Marks a record match proposed as rejected, once its candidate is
  # rejected, so lookups stop treating it as a live record. A record a human
  # has reviewed is left alone.
  def retire(candidate, crawl_run:)
    result = fact_writer.write(candidate.kind, { id: candidate.subject_id }, protect_human_verified: true,
      verification: { status: "rejected", by: "agent:verifier/#{crawl_run.model || 'unknown'}" })
    write_result(result)
  end

  # Whether the candidate's source still says exactly what the fact it's
  # attached to records (#240; Directory::FactWriter#confirm). On a match, the
  # source's evidence on the fact is stamped as checked; nothing else is
  # written. fact_id: the fact to compare with, when the candidate isn't
  # attached to it (a closed fact). Returns the FactWriter::Confirmation, or
  # nil with no fact.
  # in_source: whether the source still contains a quote (the plug-in's
  # quote_in_source?), so the fact's other evidence from it is stamped too.
  # nil too when the source's last fetch failed (it keeps its old content but
  # moves fetched_at): that's no fresh check.
  def confirm(candidate, fact_id: candidate.subject_id, rows_sha256: candidate.source.extracted_rows_sha256, in_source: nil, add_evidence: false)
    return unless fact_id
    return if candidate.source.status_reason.present?

    attributes = candidate.payload.except(*WRITE_SKIPPED).symbolize_keys.merge(id: fact_id)
    # A link's ends as the payload names them, found afresh, so a claim
    # attached to the wrong link (#226) doesn't pass as the same claim.
    attributes.merge!(link_end_ids(candidate.payload)) if LINK_KINDS.include?(candidate.kind)
    # A deal term's end is its link: the company (#396), or the link its
    # ends and verb name (#256).
    attributes = deal_term_link(candidate.payload, attributes) if candidate.kind == "deal_term"
    # Checked when the source was read, not when this ran.
    fact_writer.confirm(candidate.kind, attributes, source_id: candidate.source_id, quote: candidate.quote, in_source:, rows_sha256:,
      at: candidate.source.fetched_at || Time.current, source_kind: candidate.source.source_kind, add_evidence:)
  end

  # A source read again with the same rows: all its evidence was checked at:.
  def reconfirm_source(source_id:, facts:, quotes:, rows_sha256:, at:)
    fact_writer.reconfirm_source(source_id:, facts:, quotes:, rows_sha256:, at:)
  end

  # The existing link (or record) these attributes name, with its decision,
  # or nil. Reads only.
  def existing_fact(kind, attributes)
    id = fact_writer.existing(kind, attributes) or return
    fact(type: type_for(kind), id:)
  end

  # Payload key of an enrichment candidate: how to find the existing record
  # it adds values to. Enrichment never creates records.
  ENRICHMENT_KEY = "identify"
  # Payload keys a write never stores as values.
  WRITE_SKIPPED = [ *LINK_ENDS, *PAYLOAD_LOCKED, ENRICHMENT_KEY ].freeze

  def enrichment?(candidate) = candidate.payload.to_h.key?(ENRICHMENT_KEY)

  # The site an enriched NRC unit belongs under: the live (not rejected or
  # unpublished) site with the EIA plant ID the candidate named. nil when the
  # unit already has a site, which is never changed (a seed site such as Plant
  # Vogtle keeps its units), or when EIA hasn't proposed that site yet.
  def site_for_unit(candidate)
    plant = candidate.payload.to_h.dig(ENRICHMENT_KEY, "eia_plant_id").presence or return
    unit = candidate.subject_id && lookup.facility(id: candidate.subject_id) or return
    return if unit.parent_id || unit.nrc_docket.blank?

    site = lookup.facility(eia_plant_id: plant) or return
    site.id unless site.id == unit.id || %w[rejected unpublished].include?(site.verification_status)
  end

  # Site fields a verified unit can fill in when the site has none.
  SITE_FIELDS_FROM_UNIT = %w[state facility_type status country_code latitude longitude].freeze

  # After a unit is verified, fills its site's blank fields (state, type,
  # status) from the unit, with the unit's quote as evidence. Never
  # overwrites a field the site already has, and leaves the site's
  # verification alone. Returns nil when the unit has no site or nothing is
  # left to fill, else a WriteResult: success; an error when a human rejected
  # the site; or a conflict when the unit disagrees with a value a human
  # recorded for the site (nothing written, even if no field was blank). The
  # quote is evidence just for the fields it fills.
  # The values come from the unit as stored, not from the candidate, since
  # a curated unit may have kept its own values over the candidate's.
  # Only a unit that ended up verified speaks for its site (a human may have
  # kept it rejected); FactWriter checks that, and which fields are blank,
  # with both records locked.
  # Only the fields this candidate states are filled, so the site's evidence
  # is the document that stated them (an NRC row doesn't vouch for EIA's
  # coordinates; the EIA candidate fills those when it's published).
  def fill_site_from_unit(facility_id, candidate, crawl_run:)
    stated = candidate.payload.keys & SITE_FIELDS_FROM_UNIT
    return if stated.empty?

    result = fact_writer.fill_site_from_unit(facility_id, fields: stated,
      evidence: [ { source_id: candidate.source_id, quote: candidate.quote, found_by: "crawler", crawl_run_id: crawl_run&.id } ])
    write_result(result) if result
  end

  # For the review screens (DataQuality::Review, #85).

  # The six fact kinds, e.g. "organization", "facility_relationship".
  def fact_kinds = "Directory::Lookup::FACT_KINDS".constantize

  # Any fact (links included) with its decision and stored values, or nil.
  def organization_by_slug(slug) = lookup.organization(slug:)
  def facility_by_slug(slug) = lookup.facility(slug:)
  def evidence_rows(type:, id:) = lookup.evidence_rows(type:, id:)

  # A company name kept as a lead, never thrown away (#548).
  def keep_lead(name:, key:, label:, url: nil) = Directory::Leads.keep(name:, key:, label:, url:)

  def fact(type:, id:)
    state = lookup.fact_state(type:, id:) or return
    record(type, state, values: lookup.fact_attributes(type:, id:))
  end

  # The companies that publicly own this plant or unit now (#382), as ids.
  def published_owner_ids(facility_id:) = lookup.published_owner_ids(facility_id:)

  # Whether a fact is public now (its model's published scope).
  def published?(type:, id:) = lookup.published?(type:, id:)

  # Published companies' and plants' names and aliases, by type (#127).
  def published_names = lookup.published_names

  # Ids of sources behind published facts (#510).
  def published_source_ids = lookup.published_source_ids

  # Of these facts of one type, the ids a person decided (verified_by human:…).
  def human_decided_ids(type:, ids:) = lookup.human_decided_ids(type:, ids:)

  # Whether a company or plant already goes by this name (normalized).
  def known_name?(type:, id:, name:) = lookup.known_name?(type:, id:, name:)

  # Holds a fact's row lock until the surrounding transaction ends.
  def lock_fact(type:, id:) = lookup.lock_fact(type:, id:)

  # Whether a fact has any evidence (a source) at all.
  def sourced?(type:, id:) = lookup.sourced?(type:, id:)

  # Facts of one kind waiting for a human (Directory::PendingFactRef), oldest first.
  def pending_facts(kind:, after_id: nil, limit: 50) = lookup.pending_facts(kind:, after_id:, limit:)

  # How many public facts have evidence from these sources.
  def published_count_backed_by(source_ids:) = lookup.published_count_backed_by(source_ids:)

  # Ids of every pending fact of one kind.
  def pending_fact_ids(kind:) = lookup.pending_fact_ids(kind:)

  # Every verification decision on a fact, newest first (Directory::VerificationEventRef).
  def verification_history(type:, id:) = lookup.verification_history(type:, id:)

  # A fact's evidence (Directory::EvidenceRef).
  def evidence(type:, id:) = lookup.evidence(type:, id:)

  # Whether a correction report on the fact's public page (a link's, either
  # end's) is still unresolved.
  def open_corrections?(type:, id:) = lookup.open_corrections?(type:, id:)

  MERGES = { "Organization" => :merge_organization, "Facility" => :merge_facility }.freeze

  # A person's merge of one company or plant site into another (#142), as the
  # merge rake tasks do it: everything moves to into, from is unpublished
  # with a reason saying what moved, and its address redirects. With
  # dry_run it only reads (FactWriter.merge_preview), taking no locks, to
  # say what it would move (#325). Returns [WriteResult, what moved
  # ("3 aliases, 2 claims") or nil].
  def merge(type, from_id:, into_id:, by:, reason: nil, dry_run: false)
    method = MERGES.fetch(type)
    if dry_run
      result, moved = fact_writer.merge_preview(type:, from_id:, into_id:)
      return [ write_result(result), (claims_word(moved) if result.errors.empty?) ]
    end

    result = moved = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      # The claims on both records are locked first, in the order an approval
      # takes (source, claim, then the fact), so a merge and an approval of
      # one of those claims never wait on each other.
      # A site's units too: approving a unit's claim locks the unit, then its site.
      units = type == "Facility" ? lookup.unit_ids(site_ids: [ from_id, into_id ]) : []
      claims = ::Candidate.where(subject_type: type, subject_id: [ from_id, into_id, *units ])
      ::Source.where(id: claims.select(:source_id)).order(:id).lock.to_a
      claims.order(:id).lock.to_a
      result = write_result(fact_writer.public_send(method, from_id:, into_id:, by:, reason:))
      # In the admin's words: candidates are claims.
      moved = claims_word(verification_history(type:, id: from_id).first&.reason.to_s[/Moved: (.*)\z/, 1]) if result.errors.empty?
    end
    @plant_names = nil
    [ result, moved ]
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    [ WriteResult.new(ref: nil, errors: [ "someone was deciding on one of its claims just then; try again" ]), nil ]
  end

  # Moves open claims left on a merged-away record to the one kept (#325).
  # Returns how many moved.
  def repoint_merged_claims = fact_writer.repoint_merged_claims

  # A human's decision on a directory fact: status "verified" (approve or
  # republish, optionally with edited attributes), "rejected" or
  # "unpublished". Human writes aren't protected; the reason and context go
  # to the audit trail. Returns a WriteResult.
  def decide_fact(kind, id:, status:, by:, reason: nil, attributes: {}, context: nil)
    result = fact_writer.write(kind, attributes.to_h.symbolize_keys.merge(id:),
      verification: { status:, by:, reason:, context: }.compact)
    write_result(result)
  end

  # Add a fact and Publish (#202): see Directory::Lookup.
  def company_fact_key?(kind, key) = lookup.company_fact_key?(kind, key)
  def company_fact_status(organization_id:, kind:, key:) = lookup.company_fact_status(organization_id:, kind:, key:)
  def publish_counts(type:, id:, added_reason:) = lookup.publish_counts(type:, id:, added_reason:)

  # A website's domain, as a company's is stored and matched.
  def domain_from(url) = lookup.domain_from(url)

  # A record or fact a person adds by hand (#202): written pending, with
  # its source's quote as evidence, recorded as `by`. Publishing it is a
  # separate decision. Returns a WriteResult.
  def add_fact(kind, attributes, source_id:, quote:, by:, reason:)
    result = fact_writer.write(kind, attributes.to_h.symbolize_keys, create_only: true,
      evidence: [ { source_id:, quote:, found_by: "human" } ], verification: { status: "pending", by:, reason: })
    write_result(result)
  end

  # What setting these plant records (a site and its units) to status would
  # change, without writing. Returns a StatusResult.
  def status_change_plan(ids:, status:) = status_result { status_change.plan(ids:, status:) }

  # Sets their status as `by`'s decision (Directory::StatusChange.apply).
  # Returns a StatusResult.
  def set_status(ids:, status:, by:, reason:, source_id: nil, quote: nil)
    status_result { status_change.apply(ids:, status:, by:, reason:, source_id:, quote:) }
  end

  # NRC's power status file's newest line for this plant: [source_id, quote], or nil.
  def nrc_status_quote(name) = status_change.nrc_quote(name)

  # A human removes one piece of evidence from a fact (see
  # Directory::FactWriter#remove_evidence). Returns a WriteResult.
  def remove_evidence(type:, id:, evidence_id:, source_id:, quote:, by:, reason:)
    write_result(fact_writer.remove_evidence(type:, id:, evidence_id:, source_id:, quote:, by:, reason:))
  end

  private
    # A news item (#137): the item (the same one by its link), then the
    # companies and plants match found it's about. One about nothing in the
    # directory isn't written; one whose company or plant was taken off since
    # is refused, item and mentions together, without stopping the batch.
    def write_news(candidate, verification:, evidence:, by: nil)
      payload = candidate.payload.to_h
      mentions = Array(payload["mentions"])
      if candidate.subject_id.nil? || mentions.empty?
        return WriteResult.new(ref: nil, errors: [ "it isn't about a company or plant in the directory yet" ])
      end

      attributes = payload.slice("url", "title", "publisher", "published_on", "summary").symbolize_keys
      result = nil
      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          # As any fact: an automated write never overwrites a person's decision.
          result = fact_writer.write(:news_item, attributes, evidence:, verification:, protect_human_verified: by.nil?)
          raise ActiveRecord::Rollback unless result.ok?

          mentions.each { |type, id| Directory::FactWriter.mention_news(news_item_id: result.id, subject_type: type, subject_id: id) }
        end
      rescue Directory::FactWriter::Invalid => error
        return WriteResult.new(ref: nil, errors: [ error.message ])
      end
      write_result(result)
    end

    # "X is also known as Y": the alias goes on its company, which must be
    # published already (approving an alias doesn't publish a company).

    def write_alias(candidate, verification:, evidence:, by:)
      ends = candidate.payload["organization"].to_h
      company = (organization(name: ends["name"]) if ends["name"].present?) ||
        (organization(domain: ends["domain"]) if ends["domain"].present?)
      unless company
        return WriteResult.new(ref: nil, errors: [ "no company named #{(ends['name'] || ends['domain']).to_s.inspect} to add the alias to" ])
      end
      unless company.verification_status == "verified"
        return WriteResult.new(ref: company.ref, errors: [ "#{company.name} isn't published; approve it first, then this alias" ])
      end
      return WriteResult.new(ref: company.ref, errors: [ "only a human adds an alias" ]) unless by

      alias_name = candidate.payload["alias"].to_s.strip
      return WriteResult.new(ref: company.ref, errors: [ "the alias is blank" ]) if alias_name.empty?

      write_result(fact_writer.write("organization", { id: company.id, aliases: [ alias_name ] }, evidence:,
        verification:, protect_human_verified: false))
    end

    # { organization_id: 12, facility_id: 40 } for the ends a link payload
    # names: a company by name (or alias) or domain, a plant by docket, EIA
    # plant ID or name. An end that isn't found is nil.
    # A deal term's attributes with its ends replaced by its link's id.
    def deal_term_link(payload, attributes)
      ends = attributes.extract!(:organization_id, :facility_id, :from_organization_id, :to_organization_id)
      link_kind = DataQuality::Stages::Match::DEAL_LINKS[payload["link_type"]]
      return attributes.merge(link_id: ends[:organization_id]) unless link_kind

      # Both ends must be found: with one missing, the other end and the verb
      # alone could pick some other link.
      needed = link_kind == "relationship" ? %i[from_organization_id to_organization_id] : %i[organization_id facility_id]
      link = (existing_fact(link_kind, ends.slice(*needed).merge(relationship_type: payload["relationship_type"])) if needed.all? { |key| ends[key] })
      attributes.except(:relationship_type).merge(link_id: link&.id)
    end

    def link_end_ids(payload)
      LINK_ENDS.each_with_object({}) do |key, ids|
        named = payload[key]
        next unless named.is_a?(Hash)

        found =
          if key == "facility"
            (facility(nrc_docket: named["nrc_docket"]) if named["nrc_docket"].present?) ||
              (facility(eia_plant_id: named["eia_plant_id"]) if named["eia_plant_id"].present?) ||
              (facility(name: named["name"]) if named["name"].present?)
          else
            # Government IDs first (the SEC's CIK, EIA's utility ID), as Match and FactWriter find a company.
            (organization(sec_cik: named["sec_cik"]) if named["sec_cik"].present?) ||
              (organization(eia_utility_id: named["eia_utility_id"]) if named["eia_utility_id"].present?) ||
              (organization(name: named["name"]) if named["name"].present?) ||
              (organization(domain: named["domain"]) if named["domain"].present?)
          end
        ids[:"#{key}_id"] = found&.id
      end
    end

    # Resolved lazily so the module has no load-time dependency on the directory.
    def lookup = @lookup ||= "Directory::Lookup".constantize
    def fact_writer = @fact_writer ||= "Directory::FactWriter".constantize
    def status_change = "Directory::StatusChange".constantize

    def status_result
      StatusResult.new(plan: yield, error: nil)
    rescue status_change::Invalid => error
      StatusResult.new(plan: nil, error: error.message)
    end

    # In the admin's words: candidates are claims.
    def claims_word(moved) = moved&.gsub(/\bcandidate(s?)\b/, "claim\\1")

    # Read once and reused for every brand check, until a facility or company is written.
    def plant_names = @plant_names ||= lookup.plant_names(owners: owner_hints)

    def record(type, ref, values: nil)
      Record.new(type:, id: ref.id, name: ref.name, domain: ref.try(:domain), sec_cik: ref.try(:sec_cik), eia_utility_id: ref.try(:eia_utility_id),
        nrc_docket: ref.try(:nrc_docket), eia_plant_id: ref.try(:eia_plant_id), parent_id: ref.try(:parent_id),
        facility_type: ref.try(:facility_type), status: ref.try(:status), city: ref.try(:city), state: ref.try(:state),
        country_code: ref.try(:country_code), verification_status: ref.verification_status,
        verified_by: ref.try(:verified_by), verified_at: ref.try(:verified_at), values:) if ref
    end

    def write_result(result)
      # Plant names depend on facilities and on company names (owner prefixes).
      @plant_names = nil if result.ok? && %w[facility organization].include?(result.kind.to_s)
      if result.ok?
        WriteResult.new(ref: Ref.new(type: type_for(result.kind), id: result.id), errors: [], created: result.created)
      elsif result.conflict?
        WriteResult.new(ref: Ref.new(type: type_for(result.kind), id: result.id), errors: Array(result.errors),
          conflicts: result.conflicts)
      else
        WriteResult.new(ref: nil, errors: Array(result.errors).presence || [ "unknown error" ])
      end
    end

    # Fact kind => the record type candidates store, e.g. "facility_relationship"
    # => "FacilityRelationship". Kinds are named after their records.
    def type_for(kind) = kind.to_s.camelize
end
