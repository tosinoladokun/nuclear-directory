require "yaml"

module Seed
  # Loads the hand-checked organization files in db/seeds/organizations/
  # (researched in #8, #30, #60 and #63, approved by Tosin) and the plant
  # details in db/seeds/facilities.yml through Directory::FactWriter.
  #
  # Every fact is marked verified by human:tosin and gets one evidence row
  # (found_by: human) pointing at the source page and quote from the file.
  # A fact marked `pending: true` (with a `pending_reason`, kept in the YAML)
  # is created pending instead, for Tosin to approve in the admin, and the
  # seed never changes a decision already made on it.
  # Safe to re-run: FactWriter updates existing facts, never duplicates them.
  # All or nothing: if any fact fails, nothing is written and Error lists why.
  #
  # Not loaded: each file's `notes` (research notes, kept in the YAML).
  # facilities.yml's other_names become facility aliases (#65); they also
  # find a plant an earlier seed stored under a former name, so a rerun
  # renames it rather than creating it again.
  class OrganizationLoader
    class Error < StandardError; end

    VERIFICATION = { status: "verified", by: "human:tosin" }.freeze
    # A row's state across its writes: the first listed wins.
    STATES = %i[created changed unchanged].freeze

    FACILITY_FIELDS = %w[facility_type status city state].freeze

    # facilities: the plant-details file; defaults to facilities.yml next to dir.
    def initialize(dir, facilities: File.join(File.dirname(dir), "facilities.yml"))
      @files = Dir[File.join(dir, "*.yml")].sort
      @facilities_file = facilities
      # What happened to each row written: { [kind, id] => :created | :changed | :unchanged }.
      @rows = {}
      @errors = []
    end

    # Per kind, the rows the seed created, changed (an existing fact it
    # changed) and left unchanged (only restated), so a re-seed's report
    # shows what moved (#301). Each row counts once, however many writes it
    # took: created over changed over unchanged.
    def results
      @rows.each_with_object(Hash.new { |h, kind| h[kind] = { created: 0, changed: 0, unchanged: 0 } }) do |((kind, _id), state), counts|
        counts[kind][state] += 1
      end
    end

    # Dry run: every name, alias or domain in the files that the database
    # already gives to a different organization, which would fail the load.
    # A name listed under merges: doesn't count (it's merged first). Writes
    # nothing.
    def collisions
      docs = @files.to_h { |path| [ File.basename(path, ".yml"), read(path) ] }
      # A website several files share gives no domain when loaded, so it can't collide.
      shared = shared_domains(docs)
      docs.flat_map do |slug, doc|
        merging = Array(doc["merges"]).map { |name| OrganizationAlias.normalize(name) }
        names = [ doc["name"], *doc["aliases"] ].compact_blank
        target = Organization.find_by(slug:) ||
          names.lazy.filter_map { |name| OrganizationAlias.find_by(normalized_alias: OrganizationAlias.normalize(name))&.organization }.first
        owners = names.filter_map do |name|
          owner = OrganizationAlias.find_by(normalized_alias: OrganizationAlias.normalize(name))&.organization
          [ name, owner ] if owner && owner != target && !merging.include?(OrganizationAlias.normalize(owner.name))
        end
        domain = Organization.domain_from(doc["website"])
        owner = Organization.find_by(domain:) if domain && !shared.include?(domain)
        owners << [ "domain #{domain}", owner ] if owner && owner != target && !merging.include?(OrganizationAlias.normalize(owner.name))
        owners.map { |name, other| "#{slug}: #{name.inspect} already belongs to #{other.name} (#{other.slug})" }
      end + plant_id_collisions
    end

    # A licensing stage the seed would verify from a source that isn't an
    # NRC record (#379). The write itself refuses to verify such a stage, so
    # this lists them before the load, while it can still be fixed. Reads
    # the files; writes nothing.
    def licensing_source_problems
      @files.flat_map do |path|
        doc = read(path)
        slug = File.basename(path, ".yml")
        Array(doc["licensing"]).filter_map do |item|
          next if nrc_record?(item["source_url"], item["quote"])

          on = item["design_name"].present? ? "design #{item["design_name"].inspect}" : "facility #{item["facility"].inspect}"
          "#{slug}.yml: licensing #{item["stage"].inspect} for #{on}, docket #{item["nrc_docket"]}, " \
            "isn't cited to an NRC record: #{item["source_url"].inspect}"
        end
      end
    end

    # Whether a source is an NRC record (#379): a page on nrc.gov, or a
    # government publication that names the Nuclear Regulatory Commission.
    def nrc_record?(url, quote = nil)
      domain = begin
        URI.parse(url.to_s).host.to_s.downcase.delete_prefix("www.")
      rescue URI::InvalidURIError
        ""
      end

      # A source already stored may be named by its title (a Federal Register
      # notice whose address is only a number), as FactWriter reads it.
      LicensingStage.nrc_record?(domain:, url:, title: Source.find_by(url: url.to_s.strip)&.title, quote:)
    end

    # A plant (site) by name: one with no parent first, as write_unit finds
    # a site (undocketed before docketed), so a same-name NRC unit never
    # takes the site's details.
    # A site by name: undocketed, with no parent (as write_unit finds one).
    def site_named(name) = Facility.where(parent_id: nil, nrc_docket: nil).where("LOWER(name) = LOWER(?)", name.to_s).order(:id).first

    def plant_named(name)
      Facility.where(parent_id: nil).where("LOWER(name) = LOWER(?)", name.to_s).order(Arel.sql("nrc_docket IS NOT NULL"), :id).first ||
        Directory::Lookup.facility(name:)
    end

    # An EIA plant ID another site holds (#229): merge that site in first.
    def plant_id_collisions
      facilities = File.exist?(@facilities_file.to_s) ? Array(read(@facilities_file)["facilities"]) : []
      facilities.select { |entry| entry["eia_plant_id"].present? }.filter_map do |entry|
        holder = Facility.find_by(parent_id: nil, eia_plant_id: entry["eia_plant_id"].to_s) or next
        # The site the loader would write to, found as it finds it: by its
        # name, then by a former one (rename_from_former_name).
        # A site under its name or a former one comes before a same-name NRC unit.
        names = [ entry["name"], *entry["other_names"] ].compact_blank
        target = names.lazy.filter_map { |name| site_named(name) }.first || names.lazy.filter_map { |name| plant_named(name) }.first
        next if holder.id == target&.id

        "facilities.yml: #{entry['name'].inspect}'s EIA plant ID #{entry['eia_plant_id']} already belongs to " \
          "#{holder.name} (#{holder.slug}); merge it in first: bin/rails \"directory:merge_facility[#{holder.id},#{target&.id || '<site id>'}]\""
      end
    end

    def load!
      docs = @files.to_h { |path| [ File.basename(path, ".yml"), read(path) ] }
      facilities = File.exist?(@facilities_file.to_s) ? Array(read(@facilities_file)["facilities"]) : []

      ActiveRecord::Base.transaction do
        items = docs.values.flat_map { |doc| evidence_items(doc) } +
          facilities.flat_map { |facility| facility.values_at(*FACILITY_FIELDS).select { |f| f.is_a?(Hash) } }
        @confidence = confidence_by_quote(items)
        sources = write_sources(items)
        # Facts can't cite a source that wasn't saved, so stop here.
        raise Error, "Seed failed, nothing was written:\n  #{@errors.join("\n  ")}" if @errors.any?
        shared = shared_domains(docs)

        docs.each { |slug, doc| merge_former_organizations(slug, doc) }
        facilities.each { |facility| rename_from_former_name(facility) }
        # Organizations first, so relationships can find the other side.
        docs.each { |slug, doc| write_organization(slug, doc, sources, shared) }
        docs.each { |slug, doc| write_facts(slug, doc, sources) }
        # A site named only as a unit's site: (#472) is in a file too.
        in_docs = docs.values.flat_map { |doc| Array(doc["facilities"]).flat_map { |item| [ item["name"], item["site"].to_s.strip.presence ] } }.compact.to_set
        facilities.each { |facility| write_facility_details(facility, sources, in_docs) }
        # Last, once every file's plants exist: a stage can name a plant
        # another company's file defines (#379).
        docs.each { |slug, doc| write_licensing_stages(slug, doc, sources) }

        raise Error, "Seed failed, nothing was written:\n  #{@errors.join("\n  ")}" if @errors.any?
      end
      self
    end

    private
      # One sources row per URL. Sources belong to the data quality module,
      # so they're created through its entry point, not FactWriter.
      def write_sources(items)
        items.select { |item| item["source_url"] }.group_by { |item| item["source_url"] }.to_h do |url, group|
          published_on = group.filter_map { |item| item["published"] }.min
          result = DataQuality::Sources.find_or_create(url: url, published_on: published_on)
          @errors << "source #{url.inspect}: #{result.errors.join('; ')}" unless result.ok?
          [ url, result.ref&.id ]
        end
      end

      def evidence_items(doc)
        links = [ *doc["relationships"], *doc["facilities"] ].compact
        # A term's citation as it'll be written (its own quote, on its own page
        # or its link's), so its confidence is checked and consolidated too.
        [ *hq_entries(doc), *description_items(doc), short_description_item(doc), *doc["roles"], *doc["technologies"], *links, *doc["licensing"],
          *links.flat_map { |link| Array(link["terms"]).map { |term| citation(term, link) } } ].compact.select { |item| item["source_url"] }
      end

      # The description's quote, plus any "also" quotes that support the rest
      # of its text (from the same page unless they name their own source_url).
      def description_items(doc)
        description = doc["description"] or return []
        [ description, *Array(description["also"]).map { |extra| { "source_url" => description["source_url"] }.merge(extra) } ]
      end

      # short_description: { text, source_url, quote } (#559): the list row's
      # label, 40 characters at most, sourced like the description.
      def short_description_item(doc)
        item = doc["short_description"]
        item if item.respond_to?(:key?)
      end

      # A legal name is public only when one of the file's quotes states it
      # word for word (that quote is then its evidence); otherwise it's left
      # blank, and isn't kept as an alias either, rather than shown
      # unsourced.
      def legal_name_item(doc)
        name = doc["legal_name"].presence or return
        evidence_items(doc).find { |item| item["quote"].to_s.include?(name) }
      end

      def read(path) = YAML.safe_load_file(path, permitted_classes: [ Date ])

      # hq is one entry, or a list when research added to what the seed had
      # (later entries fill in what earlier ones left blank).
      def hq_entries(doc) = Array.wrap(doc["hq"]).compact

      # Websites shared by several organizations (a parent and its
      # subsidiaries, often) can't identify any one of them, so those
      # organizations keep the website but get no matching domain.
      def shared_domains(docs)
        docs.values.map { |doc| Organization.domain_from(doc["website"]) }.compact.tally.select { |_, n| n > 1 }.keys
      end

      def write_organization(slug, doc, sources, shared)
        hq = hq_entries(doc)
        description = doc["description"] || {}
        legal = legal_name_item(doc)
        attributes = {
          name: doc["name"], slug: slug, legal_name: (doc["legal_name"] if legal), website: doc["website"],
          aliases: doc["aliases"],
          country_code: doc["country_code"], status: doc["status"], description: description["text"],
          hq_city: hq.filter_map { |entry| entry["city"].presence }.last, hq_state: hq.filter_map { |entry| entry["state"].presence }.last
        }
        # A field the file doesn't state at all is left as it is, so a role-only
        # seed never blanks what the admin, Enrich or an earlier seed filled in
        # (Copilot, #501). A key stated as null still clears it.
        { website: "website", country_code: "country_code", legal_name: "legal_name", hq_city: "hq", hq_state: "hq" }.each do |attribute, key|
          attributes.delete(attribute) unless doc.key?(key)
        end
        # A description stated as null, or with `text: null`, clears it; one with only a source and quote (no text key) leaves the text alone.
        states_text = doc.key?("description") && (doc["description"].nil? || doc["description"].respond_to?(:key?) && doc["description"].key?("text"))
        attributes.delete(:description) unless states_text
        attributes[:domain] = nil if shared.include?(Organization.domain_from(doc["website"]))
        # An identifier, set only when the file gives it: a seed without one
        # never clears a CIK set in the admin (#129).
        attributes[:sec_cik] = doc["sec_cik"].to_s if doc["sec_cik"].present?
        attributes[:eia_utility_id] = doc["eia_utility_id"].to_s if doc["eia_utility_id"].present?
        # A display label, set only when the file gives one: a seed without
        # it never clears a short name set in the admin.
        attributes[:short_name] = doc["short_name"] if doc["short_name"].present?
        # Stated: set (null or text: null clears); not stated: left as it is.
        if doc.key?("short_description") && (doc["short_description"].nil? || short_description_item(doc)&.key?("text"))
          attributes[:short_description] = short_description_item(doc)&.dig("text")
        end

        # Which fields each quote backs (#398), by where it sits in the file.
        backs = Hash.new { |hash, item| hash[item] = [] }
        hq.each { |item| backs[item].concat({ "city" => "hq_city", "state" => "hq_state" }.select { |key, _| item[key].present? }.values) }
        description_items(doc).each { |item| backs[item] << "description" }
        backs[short_description_item(doc)] << "short_description" if short_description_item(doc)&.dig("source_url")
        backs[legal] << "legal_name" if legal
        # An unquoted legal name still finds a record an earlier seed loaded
        # under it (it's in aliases), then is removed from the aliases in the
        # same write.
        quotes = backs.filter_map { |item, fields| evidence(item, sources)&.merge(fields: fields.uniq.presence) }
        write(slug, :organization, attributes, quotes,
          remove_aliases: legal ? [] : Array(doc["legal_name"]))
      end

      def write_facts(slug, doc, sources)
        organization = Directory::Lookup.organization(slug:) or return

        Array(doc["roles"]).each do |item|
          [ item["key"], item["subtype"] ].compact.each do |role|
            write(slug, :organization_role, { organization_id: organization.id, role: role }, evidence(item, sources))
          end
        end

        Array(doc["technologies"]).each do |item|
          write(slug, :organization_technology, { organization_id: organization.id, technology: item["key"] },
            evidence(item, sources))
        end

        Array(doc["relationships"]).each do |item|
          other = Directory::Lookup.organization(name: item["to"])
          unless other
            @errors << "#{slug}: relationship to unknown organization #{item["to"].inspect}"
            next
          end

          # #251: compact drops a nil description so a second entry about the
          # same link (same from/to/type) doesn't clear a value another
          # entry set. The seed describes what's known; a missing key is
          # "nothing to say", not "clear it".
          # A link marked pending stays pending, and a human's later decision on it holds, as for plant links.
          existing = Relationship.find_by(from_organization_id: organization.id, to_organization_id: other.id, relationship_type: item["type"])
          next if item["pending"] && existing&.closed?

          link = write(slug, :relationship, { from_organization_id: organization.id, to_organization_id: other.id,
            relationship_type: item["type"], description: item["description"] }.compact,
            evidence(item, sources), pending: item["pending"], hold: held_link_reason(existing, item))
          write_terms(slug, "Relationship", link, item, sources)
        end

        Array(doc["facilities"]).each do |item|
          facility = item["site"].present? ? write_unit(slug, item, sources) : write(slug, :facility, facility_attributes(item), evidence(item, sources))
          next unless facility&.ok?
          # A pending link a human has since rejected or unpublished stays decided.
          next if item["pending"] && closed_link?(organization.id, facility.id, item["type"])

          # #251: nil-safe for ownership_pct (and the note), so a second
          # entry about the same owns-link that omits a share doesn't
          # clear the share another entry set, which was rewriting the
          # value and logging four verification events on every re-seed.
          link = write(slug, :facility_relationship, { organization_id: organization.id, facility_id: facility.id,
            relationship_type: item["type"], description: item["note"], ownership_pct: item["ownership_pct"] }.compact,
            evidence(item, sources), pending: item["pending"], hold: hold_reason(organization.id, facility.id, item))
          write_terms(slug, "FacilityRelationship", link, item, sources)
        end
      end

      # A deal's terms (#256): each one agreement under its link, with its
      # MW, money, dates, form of agreement and status, so the data piece
      # (#255) and the export (#254) read them as data. A term's key is its
      # stable id (stored as external_id), so a re-seed updates it rather than
      # adding another. Its evidence is its own quote, else the link's (citation).
      #   terms:
      #   - key: constellation-uprates-ppa-2026
      #     agreement: ppa
      #     status: signed
      #     capacity_mw: 890
      #     signed_on: 2026-10-01
      #     starts_on: 2026-10-01
      #     ends_on: 2046-09-30
      #     conditions: Illinois Commerce Commission approval   # optional: then not counted yet
      TERM_FIELDS = %w[agreement status conditions capacity_mw firm_mw amount_usd signed_on starts_on ends_on term_years].freeze

      def write_terms(slug, link_type, link, item, sources)
        terms = Array(item["terms"])
        return if terms.empty? || !link&.ok?

        link_verified = link_type.constantize.find_by(id: link.id)&.verified?
        terms.each do |term|
          unless term["key"].to_s.strip.present?
            @errors << "#{slug}: a deal term under #{item['to'] || item['name']} needs a key (a stable id, e.g. google-kairos-mpda-2024)"
            next
          end

          # A term a person rejected or unpublished stays as decided, as a
          # closed link does: a re-seed never brings it back.
          next if DealTerm.find_by(link_type:, link_id: link.id, term_type: term["type"] || "offtake", external_id: term["key"].to_s.strip)&.closed?

          # A field the entry leaves out is "nothing to say" (#251); one it
          # gives as null clears it (a condition met since, say).
          attributes = { link_type:, link_id: link.id, term_type: term["type"] || "offtake", external_id: term["key"].to_s.strip }
            .merge(TERM_FIELDS.select { |field| term.key?(field) }.to_h { |field| [ field.to_sym, term[field] ] })
          # Pending only while the link itself is: once a person approves the
          # link, its terms are verified with it, though the YAML still says pending.
          write(slug, :deal_term, attributes, evidence(citation(term, item), sources), pending: item["pending"] && !link_verified)
        end
      end

      def write_licensing_stages(slug, doc, sources)
        organization = Directory::Lookup.organization(slug:) or return

        Array(doc["licensing"]).each { |item| write_licensing_stage(slug, organization, item, sources) }
      end

      # A licensing stage (#379): the NRC stage a project or plant has
      # reached, with its docket and the date, from an NRC record. The row
      # is on the unit that holds the docket, or on the developer for a
      # design approval.
      def write_licensing_stage(slug, organization, item, sources)
        # A pending stage couldn't be reviewed: licensing stages aren't in
        # the admin's review list yet. Leave a lead out until an NRC record
        # states the stage.
        if item["pending"]
          return @errors << "#{slug}: licensing #{item['stage'].inspect}: pending: isn't supported for licensing stages; " \
            "add the stage once an NRC record states it"
        end

        attributes = { stage: item["stage"], nrc_docket: item["nrc_docket"], effective_on: item["effective_on"] }
        attributes[:expires_on] = item["expires_on"] if item["expires_on"].present?
        if item["design_name"].present?
          attributes[:organization_id] = organization.id
          attributes[:design_name] = item["design_name"]
        else
          # The docket first, as everywhere (DATA.md, The same record): a
          # name can belong to an older site as well as the docketed unit.
          docket = LicensingStage.normalize_docket(item["nrc_docket"])
          facility = (Directory::Lookup.facility(nrc_docket: docket) if docket) ||
            (Directory::Lookup.facility(name: item["facility"]) if item["facility"].present?)
          unless facility
            @errors << "#{slug}: licensing: unknown facility #{item["facility"].inspect}"
            return
          end
          # Found by name with another docket: a typo or a missing unit, never
          # a stage on the wrong reactor.
          if docket && facility.nrc_docket.present? && facility.nrc_docket != docket
            @errors << "#{slug}: licensing: #{item["facility"]} has docket #{facility.nrc_docket}, not #{docket}"
            return
          end

          attributes[:facility_id] = facility.id
        end

        write(slug, :licensing_stage, attributes, evidence(item, sources))
      end

      # merges: names of organizations an earlier seed loaded as their own
      # company that are now part of this one (one company per brand,
      # decision #23; e.g. Urenco USA into Urenco). The earlier record is
      # merged into this one, attributed to the seed's human, so its aliases
      # and facts move here instead of colliding. Nothing to do on a fresh
      # database, or once merged.
      # One row's state, keeping the strongest seen this load (STATES).
      def count(kind, id, state)
        key = [ kind, id ]
        @rows[key] = [ state, @rows[key] ].compact.min_by { |seen| STATES.index(seen) }
      end

      # A merge changes both companies, and moves (or rejects, as a
      # duplicate) the former one's open links: each counts as changed, even
      # when a later write only restates it. A rejected or unpublished link
      # stays as it was decided, so it isn't counted.
      def count_merge(former_id, target_id)
        former = Organization.find(former_id)
        open = ->(scope) { scope.where.not(verification_status: Verifiable::CLOSED_STATUSES).ids }
        moved = { organization_role: open.(former.organization_roles), organization_technology: open.(former.organization_technologies),
          facility_relationship: open.(former.facility_relationships),
          relationship: open.(Relationship.where(from_organization_id: former_id).or(Relationship.where(to_organization_id: former_id))) }
        yield.tap do |result|
          next unless result.ok?

          [ former_id, target_id ].each { |id| count(:organization, id, :changed) }
          moved.each { |kind, ids| ids.each { |id| count(kind, id, :changed) } }
        end
      end

      def merge_former_organizations(slug, doc)
        Array(doc["merges"]).each do |name|
          former = Directory::Lookup.organization(name:) or next
          target = Directory::Lookup.organization(slug:)
          next if target && former.id == target.id
          next if former.verification_status == "unpublished" # merged on an earlier load
          next @errors << "#{slug}: can't merge #{name.inspect}: #{doc["name"].inspect} isn't loaded yet" unless target

          result = count_merge(former.id, target.id) do
            Directory::FactWriter.merge_organization(from_id: former.id, into_id: target.id, by: VERIFICATION[:by],
              reason: "One company per brand (decision #23): #{name} is part of #{doc["name"]}")
          end
          @errors << "#{slug}: merging #{name.inspect}: #{result.errors.join("; ")}" unless result.ok?
        end
      end

      # A plant loaded by an earlier seed under one of its other_names takes
      # its current name, keeping its links, unless the current name is
      # already taken. It takes the slug a fresh seed would give it too, so
      # its URL doesn't depend on which seed loaded it first.
      def rename_from_former_name(entry)
        return if site_named(entry["name"])

        # A site under a former name is renamed, even beside a same-name NRC
        # unit (a docketed Callaway and the site once called Callaway Energy Center).
        former = Array(entry["other_names"]).lazy.filter_map { |name| site_named(name) }.first
        unless former
          return if Directory::Lookup.facility(name: entry["name"])

          former = Array(entry["other_names"]).lazy.filter_map { |name| Directory::Lookup.facility(name:) }.first or return
        end
        attributes = { id: former.id, name: entry["name"] }
        slug = entry["name"].parameterize
        attributes[:slug] = slug unless Directory::Lookup.facility(slug:)
        write("facilities.yml", :facility, attributes, [])
      end

      # Plant details from facilities.yml: each field has its own source, so
      # each is written with its own evidence. The plant must already be in an
      # organization file. A field with no value (e.g. no city, with a quote
      # naming the nearest town) is kept in the YAML but not written.
      def write_facility_details(entry, sources, in_docs)
        name = entry["name"]
        # Checked against the files, not the database, so a plant left over
        # from an earlier load or a crawl doesn't let an orphan entry through.
        return @errors << "facilities.yml: #{name.inspect} isn't in any organization file" unless in_docs.include?(name)

        # Its organization-file write failed (already in @errors): nothing to fill.
        facility = plant_named(name) or return

        FACILITY_FIELDS.each do |field|
          detail = entry[field]
          next unless detail.is_a?(Hash) && detail["value"].present?

          write("facilities.yml", :facility, { id: facility.id, field.to_sym => detail["value"] }, evidence(detail, sources))
        end
        if entry["other_names"].present?
          write("facilities.yml", :facility, { id: facility.id, aliases: entry["other_names"] }, [])
        end
        # A display label, not a sourced fact (DATA.md, Names): no evidence.
        if entry["short_name"].present?
          write("facilities.yml", :facility, { id: facility.id, short_name: entry["short_name"] }, [])
        end
        # An identifier, like its names: EIA's crawl finds the site by it
        # instead of proposing a second one (#229).
        if entry["eia_plant_id"].present?
          write("facilities.yml", :facility, { id: facility.id, eia_plant_id: entry["eia_plant_id"].to_s }, [])
        end
      end

      # A facility can be mentioned in several entries, each stating only some
      # of its details, so blank details never overwrite ones already set.
      # county isn't loaded (no column); it stays in the YAML.
      def facility_attributes(item)
        item.slice("name", "facility_type", "status", "city", "state")
          .transform_values { |value| value.is_a?(String) ? value.strip : value }
          .compact_blank.symbolize_keys
      end

      # A term's citation: its own quote (from its own page, else its link's),
      # or with no quote of its own, its link's whole citation.
      def citation(term, link)
        return link if term["quote"].to_s.strip.empty?

        url = term["source_url"] || link["source_url"]
        # The link's date only for the link's own page: another page's date is unknown.
        published = term["published"] || (link["published"] if url == link["source_url"])
        { "source_url" => url, "quote" => term["quote"], "confidence" => term.fetch("confidence", link["confidence"]),
          "published" => published }.compact
      end

      # A unit given with its site ("site: Indian Point"): the site is found
      # among sites by name, or made; the unit is found under that site by
      # name, or made there, so a fresh load gives one site with its units,
      # never a unit as a plant of its own. A same-name plant without a site
      # is taken in as the unit; one under another site fails the load.
      # The site and unit are found by their own rules, never by FactWriter's
      # global name lookup (which could find a unit for a site, or a site for
      # its same-name unit): a site is an undocketed facility with no parent;
      # a unit is one under that site by name or alias. One that's missing is
      # created in place, then written by id, so the write is audited and
      # sourced but never matched elsewhere. An existing unit keeps its name.
      def write_unit(slug, item, sources)
        site_name, name = item["site"].to_s.strip, item["name"].to_s.strip
        site = Facility.where(parent_id: nil, nrc_docket: nil).where("LOWER(name) = LOWER(?)", site_name).first
        unless site
          # A new site, sourced and decided like any written by this load.
          site = Facility.create!(name: site_name)
          count(:facility, site.id, :created)
          site_result = write(slug, :facility, { id: site.id }, evidence(item, sources))
          return site_result unless site_result&.ok?
        end

        under = Facility.where(parent_id: site.id)
        unit = under.where("LOWER(name) = LOWER(?)", name).first ||
          under.where(id: FacilityAlias.where(normalized_alias: FacilityAlias.normalize(name)).select(:facility_id)).first
        unless unit
          # The same name (or another name) under another site is that site's: never moved.
          elsewhere = Facility.where.not(parent_id: [ nil, site.id ]).where("LOWER(name) = LOWER(?)", name).first ||
            Facility.where.not(parent_id: [ nil, site.id ]).where(id: FacilityAlias.where(normalized_alias: FacilityAlias.normalize(name)).select(:facility_id)).first
          if elsewhere
            @errors << "#{slug}: facility #{name}: already a unit of another site (#{Facility.where(id: elsewhere.parent_id).pick(:name)}), not #{site_name}"
            return
          end
          # A plant of its own by that name (an older fresh load) is taken in;
          # never the site itself, or a docketed unit of another plant.
          loose = Facility.where(parent_id: nil).where.not(id: site.id)
          unit = loose.where("LOWER(name) = LOWER(?)", name).first ||
            loose.where(id: FacilityAlias.where(normalized_alias: FacilityAlias.normalize(name)).select(:facility_id)).first
          unless unit
            unit = Facility.create!(name:, parent_id: site.id)
            count(:facility, unit.id, :created)
          end
        end
        write(slug, :facility, facility_attributes(item).except(:name).merge(id: unit.id, parent_id: site.id), evidence(item, sources))
      end

      # nil when the file gives no source (e.g. an HQ city stated without one).
      def evidence(item, sources)
        return unless item["source_url"]

        { source_id: sources.fetch(item["source_url"]), quote: item["quote"], found_by: "human",
          confidence: @confidence.fetch([ item["source_url"], item["quote"] ], item["confidence"]) }
      end

      # One confidence per quote: the same quote from the same page, cited in
      # two places (a company's file and facilities.yml) with different
      # confidences, takes the higher everywhere. Otherwise each load would
      # write one, then the other, and a re-seed would report it changed.
      # Each confidence is checked first (a number from 0 to 1): a bad one
      # fails the load, never hidden behind a good one.
      def confidence_by_quote(items)
        cited = items.select { |item| item["source_url"] && !item["confidence"].nil? }
        bad = cited.reject { |item| valid_confidence?(item["confidence"]) }
        bad.each { |item| @errors << "#{item['source_url']}: confidence #{item['confidence'].inspect} isn't a number from 0 to 1 (quote #{item['quote'].to_s.truncate(60).inspect})" }
        (cited - bad).group_by { |item| [ item["source_url"], item["quote"] ] }
          .transform_values { |same| same.map { |item| BigDecimal(item["confidence"].to_s) }.max }
      end

      def valid_confidence?(value)
        number = value.is_a?(Numeric) ? value : BigDecimal(value.to_s)
        number.between?(0, 1)
      rescue ArgumentError, TypeError
        false
      end

      # A link an earlier seed published that this one marks pending goes back
      # to pending once, with its pending_reason as the reason (by the seed's
      # human), until a direct quote is found. A link that has ever been
      # pending (held back by a seed, or created pending and then decided by
      # Tosin in the admin) is left as it is, so a rerun never undoes a human's
      # later decision.
      def hold_reason(organization_id, facility_id, item)
        return unless item["pending"]

        link = FacilityRelationship.find_by(organization_id:, facility_id:, relationship_type: item["type"])
        return unless link&.verified?
        # A seed-verified link is decided in the write that creates it; a
        # decision from pending made later is a human's (e.g. in the admin).
        events = link.verification_events
        decided_later = events.where(from_status: "pending").where("verification_events.created_at > ?", link.created_at + 1.minute)
        return if events.where(to_status: "pending").or(decided_later).exists?

        item["pending_reason"]
      end

      # The pending reason to keep, when a link the seed marks pending was verified later by a person
      # (a decision made after the seed's own write); nil otherwise. Plant links and company links.
      def held_link_reason(link, item)
        return unless item["pending"] && link&.verified?

        events = link.verification_events
        decided_later = events.where(from_status: "pending").where("verification_events.created_at > ?", link.created_at + 1.minute)
        return if events.where(to_status: "pending").or(decided_later).exists?

        item["pending_reason"]
      end

      def closed_link?(organization_id, facility_id, type)
        FacilityRelationship.find_by(organization_id:, facility_id:, relationship_type: type)&.closed?
      end

      def write(slug, kind, attributes, evidence, pending: false, hold: nil, remove_aliases: [])
        verification = hold ? { status: "pending", by: VERIFICATION[:by], reason: hold } : (VERIFICATION unless pending)
        result = Directory::FactWriter.write(kind, attributes, evidence: Array.wrap(evidence), verification:, remove_aliases:)
        if result.ok?
          count(kind, result.id, result.created ? :created : (result.changed ? :changed : :unchanged))
        else
          @errors << "#{slug}: #{kind} #{label(attributes)}: #{result.errors.join("; ")}"
        end
        result
      end

      # What an error names: the record the fact is about.
      def label(attributes)
        attributes[:name] || attributes[:role] || attributes[:relationship_type] || attributes[:stage] || attributes[:nrc_docket]
      end
  end
end
