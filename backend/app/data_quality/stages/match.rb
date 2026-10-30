# Links each new candidate to the directory record it describes, so the
# directory never gets duplicates. Shared by all plug-ins.
#
# For every new candidate, one of three things happens:
# - Found: an exact match on NRC docket, domain or name/alias. The candidate
#   is attached to that record and nothing is written yet: its quote becomes
#   evidence (and, for an organization, its name an alias) only when a human
#   approves it (DataQuality::Review.approve).
# - Not found: a new pending record is proposed with the quote as evidence.
# - Ambiguous: identifiers point at different records, or a similar record
#   exists ("Vogtle 3" vs "Plant Vogtle Units 3 & 4"). The candidate goes to
#   needs_review with the reason. Never merged automatically.
#
# A candidate that just restates a fact a person already decided closes as
# confirmed instead of waiting for review again (#240; see #settle).
#
# Either way a matched candidate ends up with a subject. Verify then
# recommends, and a human decides whether that fact is published. Records go first, so links (who operates
# what) can find records proposed earlier in the same run.
#
# Payload for links: each end is a nested hash identifying the record, e.g.
#   facility_relationship: { "organization" => { "name" => "…" },
#     "facility" => { "name" => "…", "nrc_docket" => "05000424" }, "relationship_type" => "operates" }
# See app/data_quality/README.md.
class DataQuality::Stages::Match < DataQuality::Stage
  # Facilities before organizations: company names are checked against the
  # plant names they may end in ("NextEra Energy Seabrook"), so plants proposed
  # in the same run must already be known. Records before links, and deal
  # terms after the links and companies they belong to (#397).
  ORDER = %w[facility organization organization_role organization_technology relationship facility_relationship
    deal_term organization_alias news_item licensing_stage].freeze

  # Payload keys that name another record, and what kind of record each is.
  LINK_ENDS = {
    "organization_role" => { "organization" => :organization },
    "organization_technology" => { "organization" => :organization },
    "relationship" => { "from_organization" => :organization, "to_organization" => :organization },
    "facility_relationship" => { "organization" => :organization, "facility" => :facility },
    # A funding round on the company itself (link_type "Organization", #396);
    # a term under a link names that link's ends instead (DEAL_LINKS).
    "deal_term" => { "organization" => :organization },
    # A developer's stage on an NRC project docket before any plant exists
    # (#650): its company end; the docket and stage are the stage's own.
    "licensing_stage" => { "organization" => :organization }
  }.freeze
  # A deal term under a link (#256): the link's kind, found by its ends and verb.
  DEAL_LINKS = { "Relationship" => "relationship", "FacilityRelationship" => "facility_relationship" }.freeze
  # Agreements counted as signed power deals: these state their size (#439).
  COUNTED_AGREEMENTS = %w[ppa supply_agreement tariff_subscription].freeze
  LINK_KEYS = {
    "organization_role" => %w[role],
    "organization_technology" => %w[technology],
    "relationship" => %w[relationship_type],
    "facility_relationship" => %w[relationship_type],
    # What makes a term the same one (DATA.md): its link, its type and its external ID.
    "deal_term" => %w[link_type term_type external_id],
    # Its owner, stage and docket say which stage it is (#661's key); its
    # dates are values, compared against a decided stage, never identity.
    "licensing_stage" => %w[stage nrc_docket]
  }.freeze

  Found = Data.define(:record, :by)
  # How a found record counts as the same one: its name or an alias
  # (normalized), or an id. Not a domain, a brand or a similar name.
  EXACT = [ "name", "NRC docket", "EIA plant ID", "SEC CIK", "EIA utility ID" ].freeze
  Review = Data.define(:reason)
  # A new unit that belongs under an existing site record.
  Under = Data.define(:site)

  private
    def perform(run)
      @run = run
      @stats = { "candidates" => 0, "matched" => 0, "proposed" => 0, "needs_review" => 0, "waiting" => 0, "write_errors" => 0 }

      one_run_at_a_time do
        # Every company name in this run counts as an owner for the brand
        # rule from the start, so matching doesn't depend on candidate order.
        directory.owner_hints = candidates.status_new.where(kind: "organization").filter_map { |c| c.payload["name"] }
        rematch_settled_ends
        rematch_waiting_news
        sweep_restatements
        ORDER.each do |kind|
          candidates.status_new.where(kind: kind).find_each { |candidate| match(candidate) }
        end
        # A claim attached while a person merged its record follows the merge
        # (#325), before dropped rows are looked for, so the record kept
        # isn't taken for one its source dropped.
        repointed = directory.repoint_merged_claims
        @stats["repointed"] = repointed if repointed.positive?
        sources.crawl_ok.find_each { |source| flag_dropped(source) }
      end

      @stats
    end

    # A published fact a complete read of its source no longer lists (#240)
    # gets one review item; it's never unpublished automatically. Only after
    # a complete read: the stored snapshot was extracted and every one of its
    # candidates has been placed (a blocked fetch, a page not yet extracted,
    # or a row still waiting or unresolved flags nothing). Only facts this
    # source supported (a person approved them from it, or it confirmed
    # them). A read that would drop more than a quarter of them (or the
    # plug-in's max_dropped_share) is more likely a broken page than
    # closures, and flags nothing.
    def flag_dropped(source)
      return unless source.extracted_sha256.present? && source.extracted_sha256 == source.content_sha256 && source.status_reason.blank?

      from_source = source.candidates.where(review_origin: nil).or(source.candidates.where.not(review_origin: "dropped"))
      latest = from_source.maximum(:crawl_run_id) or return
      read = from_source.where(crawl_run_id: latest)
      return skip_dropped_check if read.where(subject_id: nil).or(read.status_new).find_each.any? { |candidate| plugin.blocks_dropped_check?(candidate) }

      listed = read.distinct.pluck(:subject_type, :subject_id).to_set
      # What this source, or an earlier edition of it, supported.
      history = Candidate.where(source_id: [ source.id, *plugin.earlier_editions(source) ])
      history = history.where(review_origin: nil).or(history.where.not(review_origin: "dropped"))
      supported = history.where(status: %w[merged confirmed]).where.not(subject_id: nil).distinct.pluck(:subject_type, :subject_id)
      dropped = supported.reject { |pair| listed.include?(pair) }.select { |type, id| directory.published?(type:, id:) }
      return checked_dropped(source) if dropped.empty?
      return skip_dropped_check if dropped.size > supported.size * plugin.max_dropped_share(source)

      dropped.each { |type, id| flag_one_dropped(source, history, type, id) }
      checked_dropped(source)
    end

    # The sources this run fully checked for dropped facts, by id (safe
    # classes' G5 asks about a claim's own source).
    def checked_dropped(source) = (@stats["dropped_checked_source_ids"] ||= []) << source.id

    def skip_dropped_check = @stats["dropped_check_skipped"] = @stats.fetch("dropped_check_skipped", 0) + 1

    # Once per absence: not again while one is open, nor after a person
    # decided one, until the source lists the fact again.
    def flag_one_dropped(source, from_source, type, id)
      sightings = from_source.where(subject_type: type, subject_id: id)
      last = sightings.order(:id).last
      # What was kept: the last claim a person approved or a read confirmed,
      # never a later proposal nobody decided (or one that was rejected).
      kept = sightings.where(status: %w[merged confirmed]).order(:id).last || last
      # Once across the document's editions: not again in a later year while
      # one is open, or after a person decided one.
      editions = [ source.id, *plugin.earlier_editions(source) ]
      return if Candidate.where(source_id: editions, subject_type: type, subject_id: id, review_origin: "dropped").where("id > ?", last.id).exists?

      payload, advice = plugin.dropped(kept.kind) ||
        [ kept.payload, "Approve to keep it as it is; if it's no longer true, unpublish it on its page." ]
      read_on = source.fetched_at&.to_date || Date.current
      # On the edition that stated what was kept, with its quote, so keeping it
      # cites that page again, never a newer one that doesn't have the row.
      kept.source.candidates.create!(kind: kept.kind, payload:, quote: kept.quote, status: "needs_review", review_origin: "dropped",
        subject_type: type, subject_id: id, crawl_run: @run,
        notes: "No longer in #{source.title.presence || source.url} as read on #{read_on}. #{advice}")
      @stats["dropped"] = @stats.fetch("dropped", 0) + 1
    end

    # Match runs can race when inserting similar records even across source
    # kinds, so only one runs at a time. A Postgres advisory lock, released
    # when the run ends.
    def one_run_at_a_time
      connection = Candidate.connection
      key = Zlib.crc32("data_quality:match")
      locked = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
      raise "Another match run is already in progress" unless locked

      yield
    ensure
      connection.select_value("SELECT pg_advisory_unlock(#{key})") if locked
    end

    def match(candidate)
      @stats["candidates"] += 1
      payload = candidate.payload.to_h

      case candidate.kind
      when "facility" then payload.key?("identify") ? match_enrichment(candidate, payload["identify"]) : match_record(candidate, payload)
      when "organization" then match_record(candidate, payload)
      when *LINK_ENDS.keys then match_link(candidate, payload)
      when "news_item" then match_news(candidate, payload)
      else review(candidate, "#{candidate.kind} candidates aren't matched automatically yet")
      end
    end

    NAMES_NOTHING = "it names no company or plant in the directory".freeze

    # A waiting news item that named nothing in the directory is matched
    # again once one of the companies or plants it names is there (#536),
    # under the same locks and recheck as rematch_settled_ends.
    def rematch_waiting_news
      candidates.where(status: "needs_review", subject_id: nil, review_origin: nil, kind: "news_item").find_each do |candidate|
        next unless candidate.notes.to_s.start_with?(NAMES_NOTHING) && !DataQuality::Review.lead?(candidate)

        named = Array(candidate.payload.to_h["about"]).any? do |about|
          next false unless about.is_a?(Hash)

          hit = resolve(about["type"] == "facility" ? :facility : :organization, about.except("type"), closed: :found)
          hit.is_a?(Found) && EXACT.include?(hit.by) && !hit.record.closed?
        end
        next unless named

        notes = candidate.notes
        reopened = Candidate.transaction do
          ::Source.lock.find(candidate.source_id)
          candidate.lock!
          next false unless candidate.status_needs_review? && candidate.subject_id.nil? && candidate.review_origin.nil? && candidate.notes == notes

          candidate.update!(status: "new", ai_recommendation: nil, ai_reason: nil, ai_confidence: nil)
        end
        next unless reopened

        (@rematched ||= {})[candidate.id] = notes
        @stats["rematched"] = @stats.fetch("rematched", 0) + 1
      end
    end

    # A news item (#137) is about the companies and plants it names: each
    # found exactly (name, alias or docket) is noted as a mention, and the
    # claim is attached to the first, so it's decided with that record. One
    # naming nothing in the directory waits for a person.
    def match_news(candidate, payload)
      # A trade-press lead (#127) waits for Data Quality, whatever it names.
      return review(candidate, DataQuality::Review::LEAD) if DataQuality::Review.lead?(candidate)

      found = Array(payload["about"]).filter_map do |about|
        type = about["type"] == "facility" ? :facility : :organization
        hit = resolve(type, about.except("type"), closed: :found)
        hit.record if hit.is_a?(Found) && EXACT.include?(hit.by) && !hit.record.closed?
      end.uniq { |record| [ record.type, record.id ] }
      return review(candidate, NAMES_NOTHING) if found.empty?

      candidate.update!(payload: payload.merge("mentions" => found.map { |record| [ record.type, record.id ] }))
      attach(candidate, found.first, "About #{found.map(&:name).to_sentence}")
    end

    def match_record(candidate, payload)
      case (found = resolve(candidate.kind.to_sym, payload, closed: :found))
      when Review then review(candidate, found.reason)
      when Found
        # A decided fact the source states again is confirmed, not reviewed again (#240).
        return settle_closed(candidate, found.record, closed_reason(found)) if found.record.closed?

        # Attach only: nothing is written to an existing record until a human approves it.
        attach(candidate, found.record, "Matched existing #{found.record.name} (by #{found.by})")
        settle(candidate, found.record)
      when Under
        write(candidate, payload.symbolize_keys.merge(parent_id: found.site.id), existing: false,
          note: "New pending unit under the existing site #{found.site.name}")
      else
        # FactWriter may still find a record by a key match didn't use; trust its answer.
        write(candidate, proposal(candidate, payload))
      end
    end

    # One company per brand: a new company from a per-plant or regional legal
    # entity ("NextEra Energy Seabrook, LLC") is named after its brand
    # ("NextEra Energy"), with the legal name kept as an alias.
    def proposal(candidate, payload)
      attributes = payload.symbolize_keys
      brand = directory.brand_name(attributes[:name]) if candidate.kind_organization? && attributes[:name].present?
      return attributes unless brand

      attributes.merge(name: brand, aliases: [ *attributes[:aliases], attributes[:name] ])
    end

    # Only the fields that identify a link (LINK_KEYS and the resolved ends)
    # are written at match; its description, dates and ownership are applied
    # when it's published, so an existing link never takes on unverified
    # values. (A new link is pending, so nothing public is missing meanwhile;
    # like any proposal, it gets the quote as evidence.)
    def match_link(candidate, payload)
      if candidate.kind == "deal_term" && !(payload["link_type"] == "Organization" || DEAL_LINKS.key?(payload["link_type"]))
        return review(candidate, "a deal term's link_type must be Organization, Relationship or FacilityRelationship, not #{payload['link_type'].inspect}")
      end
      if candidate.kind == "deal_term" && DEAL_LINKS.key?(payload["link_type"])
        # A rerun must find the same term (unique by link, type and ID), and a
        # counted offtake needs its size (deal_terms_offtake_check, Database).
        return review(candidate, "a deal needs an external_id, so reading it again updates the same term") if payload["external_id"].blank?
        if payload["term_type"] == "offtake" && payload["capacity_mw"].blank? && payload["amount_usd"].blank? &&
            (payload["agreement"].blank? || COUNTED_AGREEMENTS.include?(payload["agreement"]))
          return review(candidate, "an offtake states its size (capacity_mw or amount_usd) unless it's a framework, MOU or similar")
        end
      end

      attributes = payload.slice(*LINK_KEYS.fetch(candidate.kind)).symbolize_keys
      # A design approval is also known by its design's name (#661).
      attributes[:design_name] = payload["design_name"] if candidate.kind == "licensing_stage" && payload["stage"] == "design_approval"
      closed_end = nil

      link_ends(candidate.kind, payload).each do |key, type|
        unless payload.key?(key)
          return review(candidate, "payload has no #{key}")
        end
        unless payload[key].is_a?(Hash)
          return review(candidate, "payload #{key} must be an object")
        end

        case (found = resolve(type, payload[key], closed: :found))
        when Review then return review(candidate, "#{key}: #{found.reason}")
        when Found then attributes[:"#{key}_id"] = found.record.id
        else return review(candidate, "#{key} #{label(payload[key]).inspect} isn't in the directory yet")
        end
        # A closed end, or a unit under a closed site, is kept aside: an
        # existing link to it may still be confirmed, but nothing is written.
        closed_end ||= Review.new("#{key}: #{closed_reason(found)}") if found.record.closed?
        if !closed_end && found.record.parent_id && (site = directory.facility(id: found.record.parent_id))&.closed?
          closed_end = Review.new("#{key}: its site #{site.name} was #{site.decision}. The same thing again?")
        end
      end

      # A deal term's one end is its link: the company, for a round; for a
      # deal, the open link its ends and verb name (#256), which must exist
      # first. A term never creates or reopens its link.
      if candidate.kind == "deal_term"
        if (link_kind = DEAL_LINKS[payload["link_type"]])
          ends = attributes.extract!(*link_ends(candidate.kind, payload).keys.map { |key| :"#{key}_id" })
          link = directory.existing_fact(link_kind, ends.merge(relationship_type: payload["relationship_type"]))
          return review(candidate, "#{describe_link(payload)} isn't in the directory yet: approve the link first") unless link
          return review(candidate, "#{link.name.upcase_first} was #{link.decision}, so no term is added to it") if link.closed?

          attributes[:link_id] = link.id
        else
          attributes[:link_id] = attributes.delete(:organization_id)
        end
      end

      # A link a human rejected or unpublished, or one whose company or plant
      # was, isn't written to. The same claim again is confirmed (it stays as
      # decided); anything else goes to review (#240).
      existing = directory.existing_fact(candidate.kind, attributes)
      if existing && (existing.closed? || closed_end)
        reason = closed_end&.reason || "#{existing.name.upcase_first} was #{existing.decision}. The same thing again?"
        return settle_closed(candidate, existing, reason)
      end
      return review(candidate, closed_end.reason) if closed_end

      if existing && (other = other_page_on(candidate, existing))
        return review(candidate, "#{existing.name.upcase_first} already cites #{other.title.presence || other.url}, another page of this source. " \
          "Approving this would replace what that page says, so the two need combining first (#390).")
      end

      # An existing link is attached without writing, as a record is, so a
      # read that only restates it changes nothing in the directory.
      if existing
        attach(candidate, existing, "Matched existing #{existing.name}")
        return settle(candidate, existing)
      end

      # A new term is written with its values (a round needs its amount or
      # round to exist), pending until a person approves it.
      # What match resolved wins: a payload never names the record, its company or its id.
      if %w[deal_term licensing_stage].include?(candidate.kind)
        values = payload.except(*link_ends(candidate.kind, payload).keys, "relationship_type", *DataQuality::DirectoryClient::WRITE_SKIPPED).symbolize_keys
        return write(candidate, values.merge(attributes))
      end

      write(candidate, attributes, evidence: false)
    end

    # A link claim waits in review when one of its ends had no exact match
    # ("to_organization: no exact match for …", or "… isn't in the directory
    # yet"). Once every end has one now (a name, an alias or an id), it's
    # matched again, as new. Nothing is approved: it goes on to verify and
    # a person like any claim. Never a dropped or extracted review item, a
    # claim on a record already, or one with an end still in question.
    # The ends a claim names: a deal term under a link names that link's.
    def link_ends(kind, payload)
      link_kind = (DEAL_LINKS[payload["link_type"]] if kind == "deal_term")
      LINK_ENDS.fetch(link_kind || kind)
    end

    def describe_link(payload)
      ends = payload.values_at("from_organization", "organization", "to_organization", "facility").compact.map { |named| label(named) }
      "The link #{ends.join(" #{payload['relationship_type']} ")}"
    end

    def rematch_settled_ends
      ends = LINK_ENDS.values.flat_map(&:keys).uniq.join("|")
      # Only the two missing-match holds; others (a closed site, say) stay as they are.
      # And a deal waiting for its link (#256), once that link is in.
      question = /\A(?:(?:#{ends}): no exact match for |(?:#{ends}) ".*" isn't in the directory yet|The link .* approve the link first)/
      waiting = candidates.where(status: "needs_review", subject_id: nil, review_origin: nil, kind: LINK_ENDS.keys)
      waiting.find_each do |candidate|
        next unless candidate.notes.to_s.match?(question)

        payload = candidate.payload.to_h
        ids = {}
        settled = link_ends(candidate.kind, payload).all? do |key, type|
          found = resolve(type, payload[key], closed: :found) if payload[key].is_a?(Hash)
          ids[:"#{key}_id"] = found.record.id if found.is_a?(Found)
          found.is_a?(Found) && EXACT.include?(found.by) && !found.record.closed?
        end
        if settled && candidate.kind == "deal_term" && (link_kind = DEAL_LINKS[payload["link_type"]])
          link = directory.existing_fact(link_kind, ids.merge(relationship_type: payload["relationship_type"]))
          settled = link && !link.closed?
        end
        next unless settled

        # Under the decision's locks (its source, then the claim), and only if
        # it's still waiting as it was: a person may have decided it meanwhile.
        notes = candidate.notes
        reopened = Candidate.transaction do
          ::Source.lock.find(candidate.source_id)
          candidate.lock!
          next false unless candidate.status_needs_review? && candidate.subject_id.nil? && candidate.review_origin.nil? && candidate.notes == notes

          candidate.update!(status: "new", ai_recommendation: nil, ai_reason: nil, ai_confidence: nil)
        end
        next unless reopened

        # Its old note is kept after what this run says, so its history shows why it moved.
        (@rematched ||= {})[candidate.id] = notes
        @stats["rematched"] = @stats.fetch("rematched", 0) + 1
      end
    end

    # This run's note, and for a claim matched again, the note it had.
    # A person's Same as… (#391) stays in the note through any later run.
    def noted(candidate, note)
      settled = candidate.notes.to_s[SETTLED]&.strip
      note = "#{note}. #{settled}" if settled && !note.include?(settled)
      was = @rematched&.dig(candidate.id) or return note
      "#{note}. Matched again: its company or plant is in the directory now. Was: #{was}"
    end
    SETTLED = /[^.]* settled ".*?" as [^.]*/

    # A link already citing another page of the same kind of source (another
    # USAspending recipient's awards on one company's link), which this claim
    # would change: approving it would replace what that page says (#390).
    def other_page_on(candidate, existing) = self.class.other_page_on(candidate, existing, directory:)

    # Also asked when a link claim is approved (Review), under the link's lock:
    # a claim attached before the other page's evidence was there can't be
    # stopped here.
    # Not for a deal term: a later filing of the same round (a Form D/A on its
    # own page) supersedes the earlier one, so there's nothing to combine.
    def self.other_page_on(candidate, existing, directory:)
      return if candidate.kind_deal_term?

      cited = directory.evidence(type: existing.type, id: existing.id).map(&:source_id)
      # An earlier edition of this document is superseded by it, not another page.
      # (Research pages and other plug-in-less kinds have no editions.)
      earlier = begin
        DataQuality::Plugin.for(candidate.source.source_kind).earlier_editions(candidate.source)
      rescue DataQuality::Plugin::UnknownSourceKind
        []
      end
      other = ::Source.where(id: cited - earlier, source_kind: candidate.source.source_kind).where.not(id: candidate.source_id).order(:id).first
      return unless other

      changes = DataQuality::Differences.changes(candidate, existing, directory:)
      other if changes.nil? || changes.any?
    end

    # Found, Review or nil (nothing like it exists). A closed record, one that
    # was rejected (a retired proposal, or one a human turned down) or that a
    # human unpublished, is never attached to: the candidate goes to review.
    # closed: :found hands such a record back as Found, for a caller that
    # first checks whether the source just says the same thing again.
    def resolve(type, payload, closed: :review)
      found = type == :organization ? resolve_organization(payload) : resolve_facility(payload)
      if found.is_a?(Found) && found.record.closed? && closed == :review
        return Review.new(closed_reason(found))
      end
      if found.is_a?(Under) && found.site.closed?
        return Review.new("looks like a unit of #{found.site.name}, which was #{found.site.decision}. " \
          "Under it anyway, or its own record?")
      end

      found
    end

    def closed_reason(found)
      "matches #{found.record.name} (by #{found.by}), which was #{found.record.decision}. " \
        "The same thing again, or a new record?"
    end

    def resolve_organization(payload)
      # The SEC's CIK is exact and ranks above any name (PM, #129), as in FactWriter.
      by_cik = directory.organization(sec_cik: payload["sec_cik"]) if payload["sec_cik"].present?
      return Found.new(by_cik, "SEC CIK") if by_cik
      by_utility = directory.organization(eia_utility_id: payload["eia_utility_id"]) if payload["eia_utility_id"].present?
      return Found.new(by_utility, "EIA utility ID") if by_utility

      name = payload["name"].presence
      # FactWriter derives a domain from the website unless domain was supplied.
      domain = payload.key?("domain") ? payload["domain"].presence : payload["website"].presence
      by_name = directory.organization(name:) if name
      # Its other spellings (an award's legal name) find it too, as for a plant.
      by_name ||= Array(payload["aliases"]).compact_blank.lazy.filter_map { |other| directory.organization(name: other) }.first
      by_domain = directory.organization(domain:) if domain

      if by_name && by_domain && by_name.id != by_domain.id
        return Review.new("name matches #{by_name.name} but domain matches #{by_domain.name}")
      end
      return Found.new(by_name, "name") if by_name

      # One company per brand: a legal-entity variant of exactly one existing
      # company is that company. Two candidates for the brand is ambiguous. A
      # brand counts as a name match, so it must agree with the domain too, and
      # a shared brand goes to review even when the domain picks one of them.
      brand = name ? directory.same_brand_organizations(name) : []
      if brand.many?
        domain_note = " (its domain matches #{by_domain.name})" if by_domain
        # Sorted, so the note reads the same whatever order the lookup returns (#322's flaky test).
        names = brand.map(&:name).sort_by { |n| [ n.downcase, n ] }
        return Review.new("#{name.inspect} could be the same brand as #{names.join(' or ')}#{domain_note}. Which one?")
      end
      if by_domain && brand.one? && brand.first.id != by_domain.id
        return Review.new("name is the brand of #{brand.first.name} but domain matches #{by_domain.name}")
      end
      # A per-plant name whose brand has no company yet ("NextEra Energy
      # Seabrook, LLC") must still agree with a company found by domain.
      if by_domain && brand.empty? && (inferred = directory.brand_name(name.to_s)) &&
          directory.brand_key(inferred) != directory.brand_key(by_domain.name)
        return Review.new("name is a #{inferred} company but domain matches #{by_domain.name}")
      end
      return Found.new(by_domain, "domain") if by_domain
      return Found.new(brand.first, "brand, a legal-entity variant of its name") if brand.one?

      similar(directory.similar_organizations(name.to_s), name)
    end

    def resolve_facility(payload)
      name, docket, eia_plant = payload.values_at("name", "nrc_docket", "eia_plant_id").map(&:presence)
      # EIA's plant ID is exact: the site for that plant, already proposed or linked.
      by_eia = directory.facility(eia_plant_id: eia_plant) if eia_plant
      return Found.new(by_eia, "EIA plant ID") if by_eia

      by_docket = directory.facility(nrc_docket: docket) if docket
      # An EIA plant is a site; an NRC unit of the same name ("Palisades")
      # isn't it, and mustn't hide a site of that name either.
      eia_site = eia_plant && !docket
      by = ->(other) { eia_site ? directory.facility(site_name: other) : directory.facility(name: other) }
      by_name = by.call(name) if name
      # A candidate's other names find its plant here, so it's attached
      # without writing; its aliases are added only when it's approved.
      by_name ||= Array(payload["aliases"]).compact_blank.lazy.filter_map { |other| by.call(other) }.first

      if by_docket && by_name && by_docket.id != by_name.id
        return Review.new("docket matches #{by_docket.name} but name matches #{by_name.name}")
      end
      return Found.new(by_docket, "NRC docket") if by_docket
      if by_name && docket && by_name.nrc_docket.present?
        return Review.new("name matches #{by_name.name}, which has a different docket (#{by_name.nrc_docket})")
      end
      return Found.new(by_name, "name") if by_name

      # Units with different dockets are different units, not duplicates. And
      # an EIA plant (a site, no docket) isn't a duplicate of NRC's units: it's
      # the site they belong under (#73), so only other sites count.
      others = directory.similar_facilities(name.to_s).reject do |facility|
        (docket && facility.nrc_docket.present? && facility.nrc_docket != docket) ||
          (eia_plant && !docket && facility.nrc_docket.present?)
      end
      site_for_unit(others, name, docket) || similar(others, name)
    end

    # An NRC unit ("Vogtle 3", with a docket) under a site-level record
    # ("Plant Vogtle Units 3 & 4", no docket): Under the site when that is the
    # only similar record, it is top-level, and its name covers this unit.
    # Names that list no units cover them all. Anything less clear is nil, so
    # the caller sends it to review.
    def site_for_unit(others, name, docket)
      return unless docket && others.one?

      site = others.first
      return unless site.nrc_docket.blank? && site.parent_id.nil?

      covered = site_unit_numbers(site.name)
      return Under.new(site) if covered.empty? || covered.include?(unit_number(name))

      Review.new("#{name.inspect} looks like a unit of #{site.name}, but that record only covers " \
        "unit #{covered.join(' & ')}. Add it under the site, or as its own record?")
    end

    # An enrichment source (e.g. EIA) adds values to an NRC unit that already
    # exists and never creates one. identify: { "name", "state", "unit" }.
    # The unit is the NRC unit whose name best fits (most shared distinctive
    # words, state as a tie-break; see Lookup.facility_units) and has the same
    # unit number; a plant with a single, unnumbered NRC unit takes that unit.
    # If no unit fits yet (NRC data not loaded, or the unit's own NRC record is
    # still in review), the candidate stays new and is retried on the next run.
    # More than one fit goes to review.
    def match_enrichment(candidate, identify)
      return match_site_enrichment(candidate, identify.to_h) unless identify.to_h.key?("unit")

      name, state, unit = identify.to_h.values_at("name", "state", "unit")
      number = unit.to_s[/\d+/]&.to_i
      units, same_number = enrichment_fits(name, state, number)
      chosen = same_number.first if same_number.one?
      chosen ||= units.first if same_number.empty? && units.one? && unit_number(units.first.name).nil?
      label = "#{name} unit #{unit} (#{state})"

      if chosen&.closed?
        # Rejected or unpublished: a person's decision that won't come back on
        # its own, so this is as settled as a closed record match (#118).
        settle_closed(candidate, chosen, "#{label} would be NRC unit #{chosen.name}, which was #{chosen.verification_status}")
      elsif chosen && chosen.verification_status != "verified"
        # The unit's own NRC record is still pending: enriching it would push
        # EIA's values to a record that isn't public yet (#118). Wait and
        # retry on the next match run, like a unit that doesn't exist yet.
        # (chosen is a DirectoryClient::Record wrapper without .verified?.)
        @stats["waiting"] += 1
        candidate.update!(notes: "NRC unit for #{label} isn't verified yet; retried on the next match run")
      elsif chosen
        # Attach only: the values (and their evidence) are written when verify publishes.
        attach(candidate, chosen, "#{label} is NRC unit #{chosen.name}")
        settle(candidate, chosen)
      elsif same_number.many? || (units.many? && units.none? { |record| unit_number(record.name) })
        review(candidate, "#{label} could be #{(same_number.presence || units).map(&:name).join(' or ')}")
      else
        # Includes a plant whose other units exist but not this one (Vogtle 1
        # while only Vogtle 3 and 4 are in the directory).
        @stats["waiting"] += 1
        candidate.update!(notes: "No NRC unit for #{label} yet; retried on the next match run")
      end
    end

    # A plant-level enrichment (EIA-860's Plant file, #319) adds values to a
    # site and never creates one. identify: { "eia_plant_id", "name",
    # "state", and "site_id" once a site with no EIA plant ID was found by
    # name }. The site with that EIA plant ID wins; else a power plant with
    # no EIA plant ID by name and state, looked up again on every run, so a
    # plant added after the file was read is still found (the claim then
    # records site_id, and for a site the plant ID to set, for verify's hold).
    # site_id counts only while that site still has no EIA plant ID. No site
    # yet: retried on the next run.
    def match_site_enrichment(candidate, identify)
      plant, name, state, site_id = identify.values_at("eia_plant_id", "name", "state", "site_id")
      label = "EIA plant #{plant} (#{name})"
      site = directory.facility(eia_plant_id: plant) if plant.present?
      if site.nil? && site_id.blank? && (found = plant_by_name(name, state))
        candidate.update!(payload: candidate.payload.merge("identify" => identify.merge("site_id" => found[:id]),
          "eia_plant_id" => (plant if found[:site])).compact)
        site_id = found[:id]
      end
      if site.nil? && site_id.present?
        by_name = directory.facility(id: site_id)
        site = by_name if by_name && by_name.eia_plant_id.blank?
      end

      if site.nil?
        @stats["waiting"] += 1
        candidate.update!(notes: "No site for #{label} yet; retried on the next match run")
      elsif site.closed?
        settle_closed(candidate, site, "#{label} is #{site.name}, which was #{site.verification_status}")
      else
        attach(candidate, site, "#{label} is #{site.name}#{' (by name)' if site.eia_plant_id.blank?}")
        settle(candidate, site)
      end
    end

    # The power plant with no EIA plant ID that has this name (or an alias)
    # in this state, as { id:, site: }, when exactly one does. Read once per
    # run.
    def plant_by_name(name, state)
      key = plant_name_key(name, state) or return
      @plants_by_name ||= directory.plants_without_eia_plant_id
        .flat_map { |plant| plant[:names].map { |each| [ plant_name_key(each, plant[:state]), plant.slice(:id, :site) ] } }
        .group_by(&:first).filter_map { |each_key, found| [ each_key, found.first.last ] if each_key && found.map(&:last).uniq.one? }.to_h
      @plants_by_name[key]
    end

    def plant_name_key(name, state)
      [ directory.normalize_facility_name(name), state.to_s.strip.upcase ] if name.present? && state.present?
    end

    # [units that fit the name, those of them with this unit number]
    def enrichment_fits(name, state, number)
      units = directory.facility_units(name: name.to_s, state: state.presence)
      [ units, units.select { |record| unit_number(record.name) == number } ]
    end

    # "Vogtle 3" => 3. A name without a trailing number ("Palisades") is nil.
    def unit_number(name) = name.to_s[/\s(\d+)\s*\z/, 1]&.to_i

    # "Plant Vogtle Units 3 & 4" => [3, 4]; "Susquehanna Steam Electric Station" => [].
    def site_unit_numbers(name)
      name.to_s.scan(/\bunits?\s+((?:\d+(?:\s*(?:,|&|and)\s*)?)+)/i).flatten.flat_map { |list| list.scan(/\d+/) }.map(&:to_i)
    end

    def similar(records, name)
      return if records.empty?

      Review.new("no exact match for #{name.inspect}, but similar: #{records.map(&:name).join('; ')}. " \
        "Same record, or a new one?")
    end

    # existing: whether the candidate describes a record that already exists.
    # Links don't know until FactWriter finds (or doesn't find) the link.
    def attach(candidate, record, note)
      @stats["matched"] += 1
      candidate.update!(status: "matched", subject_type: record.type, subject_id: record.id, notes: noted(candidate, note),
        proposed_subject: false)
    end

    # evidence: false for links, which may already exist; their quote is added when a human approves.
    # The write, a new link's quote and the candidate's update happen in one
    # transaction, so a stop part-way leaves nothing half-done for a rerun to
    # mistake for an existing record.
    def write(candidate, attributes, existing: nil, note: nil, evidence: true)
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        result = directory.write_pending(candidate.kind, attributes, candidate:, crawl_run: @run, evidence:)
        # A link written without evidence (so an existing one isn't changed) that
        # turned out to be new is a proposal, and a proposal carries its quote.
        if result.success? && result.created && !evidence
          with_quote = directory.write_pending(candidate.kind, { id: result.ref.id }, candidate:, crawl_run: @run)
          unless with_quote.success?
            result = with_quote
            raise ActiveRecord::Rollback
          end
        end
        next unless result.success?

        existing = !result.created if existing.nil?
        note ||= existing ? "Matched an existing record" : "No existing record; proposed a new pending one"
        # Remembered so a rejection can retire what match created, and only that.
        candidate.update!(status: "matched", subject_type: result.ref.type, subject_id: result.ref.id, notes: noted(candidate, note),
          proposed_subject: result.created)
      end

      if result.success?
        @stats[existing ? "matched" : "proposed"] += 1
        # New companies a person must create (DQ's daily report, 28 Oct).
        @stats["new_companies_proposed"] = @stats.fetch("new_companies_proposed", 0) + 1 if result.created && result.ref.type == "Organization"
        # A fact that was already there (an existing link) may be one the source just restates.
        settle(candidate, directory.attached_record(candidate)) unless result.created
      else
        review(candidate, "Directory rejected the write: #{result.errors.join('; ')}", write_error: true)
      end
    end

    # After a candidate is attached to an existing fact (#240): a person
    # decides a fact once; afterwards the source is only re-checked.
    # - published (or otherwise human-decided): the same values close the
    #   candidate as confirmed and stamp the source's evidence. Otherwise it
    #   stays matched as before: verify sends a disagreement with a
    #   human-verified value to review showing both, and a fact with no
    #   evidence from this source yet gets it when a person approves.
    # - pending: one that repeats a candidate already waiting closes as a
    #   duplicate, so the queue holds each pending fact once.
    def settle(candidate, record)
      return unless record

      if record.verification_status == "pending"
        waiting = Candidate.where(source_id: candidate.source_id, subject_type: record.type, subject_id: record.id,
          status: %w[new matched needs_review]).where.not(id: candidate.id).where("payload = ?::jsonb", candidate.payload.to_json).first
        return replace_earlier_issue(candidate, record) unless waiting

        # The one that quotes the source as it reads now is the one kept.
        if waiting.quote == candidate.quote || plugin.quote_in_source?(candidate.source, waiting.quote)
          confirmed(candidate, record, "Same as candidate ##{waiting.id}, already waiting for review")
        else
          # Locked, so a person deciding it meanwhile is never overwritten.
          waiting.with_lock do
            next unless %w[new matched needs_review].include?(waiting.status)

            waiting.update!(status: "confirmed", notes: "Replaced by candidate ##{candidate.id}: the source's row now reads differently")
            @stats["confirmed"] = @stats.fetch("confirmed", 0) + 1
          end
        end
        return
      end

      # A claim that would only add evidence confirms itself (#548): Tosin
      # decides only what's new; nobody needs to see a restatement.
      add_evidence = DataQuality::Review.evidence_only?(candidate, directory:)
      confirmation = directory.confirm(candidate, in_source: in_source(candidate), add_evidence:)
      return unless confirmation&.confirmed?

      # Counted for Data Quality's morning report: restatements that closed themselves.
      @stats["evidence_only"] = @stats.fetch("evidence_only", 0) + 1 if add_evidence
      confirmed(candidate, record, confirmed_note(record, confirmation))
    end

    # Claims matched before restatements confirmed themselves (#548), or
    # whose record was published since: each run closes this source's
    # waiting ones that would only add evidence, as match now does for new ones.
    def sweep_restatements
      candidates.status_matched.where.not(subject_id: nil).includes(:source).find_each do |candidate|
        next unless DataQuality::Review.evidence_only?(candidate, directory:)

        # Locked as a decision locks it (source, then claim), and still
        # waiting: a person's decision meanwhile stands, and no evidence is
        # added for a claim they rejected.
        Candidate.transaction do
          Source.lock.find(candidate.source_id)
          candidate.lock!
          next unless candidate.status_matched?

          record = directory.attached_record(candidate) or next
          confirmation = directory.confirm(candidate, in_source: in_source(candidate), add_evidence: true)
          next unless confirmation&.confirmed?

          # Counted as this run's input, so the run's totals add up.
          @stats["candidates"] += 1
          @stats["matched"] += 1
          @stats["evidence_only"] = @stats.fetch("evidence_only", 0) + 1
          confirmed(candidate, record, confirmed_note(record, confirmation))
        end
      end
    end

    # The same claim waiting from an earlier edition of this source (last
    # month's EIA file, as the plug-in's earlier_editions names them): only
    # the newest waits, so the queue holds each pending fact once and it
    # cites the file as it reads now. Pages of one kind that aren't editions
    # (NRC's page per plant) are never replaced.
    def replace_earlier_issue(candidate, record)
      same = Candidate.where(subject_type: record.type, subject_id: record.id, status: %w[new matched needs_review])
        .where.not(id: candidate.id).where("candidates.payload = ?::jsonb", candidate.payload.to_json)
      # An older edition arriving second (re-read, or matched later): a newer
      # one already waits with the same claim, so this one closes.
      newer = same.joins(:source).where(sources: { source_kind: candidate.source.source_kind }).where.not(source_id: candidate.source_id)
        .find { |other| plugin.earlier_editions(other.source).include?(candidate.source_id) }
      return confirmed(candidate, record, "Same as candidate ##{newer.id} from a newer issue of the source, already waiting") if newer

      editions = plugin.earlier_editions(candidate.source)
      return if editions.empty?

      earlier = Candidate.where(source_id: editions)
        .where(subject_type: record.type, subject_id: record.id, status: %w[new matched needs_review])
        .where("candidates.payload = ?::jsonb", candidate.payload.to_json)
      earlier.find_each do |older|
        older.with_lock do
          next unless %w[new matched needs_review].include?(older.status)

          older.update!(status: "confirmed", notes: "Replaced by candidate ##{candidate.id}: a newer issue of the source says the same")
          @stats["confirmed"] = @stats.fetch("confirmed", 0) + 1
        end
      end
    end

    # A record or link a human rejected or unpublished: the same claim again
    # closes as confirmed (it stays as decided); otherwise review, unattached.
    def settle_closed(candidate, record, reason)
      confirmation = directory.confirm(candidate, fact_id: record.id, in_source: in_source(candidate))
      return review(candidate, reason) unless confirmation&.confirmed?

      candidate.update!(subject_type: record.type, subject_id: record.id, proposed_subject: false)
      confirmed(candidate, record, "#{confirmed_note(record, confirmation)}; it stays #{record.verification_status}")
    end

    # Whether the candidate's source, as stored, still contains a quote.
    def in_source(candidate) = ->(quote) { plugin.quote_in_source?(candidate.source, quote) }

    # Locked as Review locks a decision (the source, then the candidate): a
    # person who approved or rejected it meanwhile keeps their decision.
    def confirmed(candidate, record, note)
      Candidate.transaction do
        Source.lock.find(candidate.source_id)
        candidate.lock!
        next unless candidate.status_new? || candidate.status_matched?

        @stats["confirmed"] = @stats.fetch("confirmed", 0) + 1
        @stats["matched"] -= 1 if candidate.status_matched?
        candidate.update!(status: "confirmed", subject_type: record.type, subject_id: record.id, notes: noted(candidate, note))
      end
    end

    def confirmed_note(record, confirmation)
      note = "Confirmed: the source still says what #{record.name} records"
      return note if confirmation.overruled.empty?

      kept = confirmation.overruled.map { |name, (stored, stated)| "#{name.humanize(capitalize: false)} #{stored} (it says #{stated})" }
      "#{note}, except where a person's decision stands: #{kept.join('; ')}"
    end

    def review(candidate, reason, write_error: false)
      @stats["write_errors"] += 1 if write_error
      @stats["needs_review"] += 1
      candidate.update!(status: "needs_review", notes: noted(candidate, reason))
    end

    def label(payload) = payload["name"] || payload["nrc_docket"] || payload.to_s
end
