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

    # An EIA plant ID another site holds (#229): merge that site in first.
    def plant_id_collisions
      facilities = File.exist?(@facilities_file.to_s) ? Array(read(@facilities_file)["facilities"]) : []
      facilities.select { |entry| entry["eia_plant_id"].present? }.filter_map do |entry|
        holder = Facility.find_by(parent_id: nil, eia_plant_id: entry["eia_plant_id"].to_s) or next
        # The site the loader would write to, found as it finds it: by its
        # name, then by a former one (rename_from_former_name).
        target = [ entry["name"], *entry["other_names"] ].compact_blank.lazy.filter_map { |name| Directory::Lookup.facility(name:) }.first
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
        in_docs = docs.values.flat_map { |doc| Array(doc["facilities"]).map { |item| item["name"] } }.to_set
        facilities.each { |facility| write_facility_details(facility, sources, in_docs) }

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
        [ *hq_entries(doc), *description_items(doc), *doc["roles"], *doc["technologies"], *doc["relationships"],
          *doc["facilities"] ].compact.select { |item| item["source_url"] }
      end

      # The description's quote, plus any "also" quotes that support the rest
      # of its text (from the same page unless they name their own source_url).
      def description_items(doc)
        description = doc["description"] or return []
        [ description, *Array(description["also"]).map { |extra| { "source_url" => description["source_url"] }.merge(extra) } ]
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
        attributes[:domain] = nil if shared.include?(Organization.domain_from(doc["website"]))

        items = [ *hq, *description_items(doc), legal ].compact.uniq
        # An unquoted legal name still finds a record an earlier seed loaded
        # under it (it's in aliases), then is removed from the aliases in the
        # same write.
        write(slug, :organization, attributes, items.filter_map { |item| evidence(item, sources) },
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

          write(slug, :relationship, { from_organization_id: organization.id, to_organization_id: other.id,
            relationship_type: item["type"], description: item["description"] }, evidence(item, sources))
        end

        Array(doc["facilities"]).each do |item|
          facility = write(slug, :facility, facility_attributes(item), evidence(item, sources))
          next unless facility&.ok?
          # A pending link a human has since rejected or unpublished stays decided.
          next if item["pending"] && closed_link?(organization.id, facility.id, item["type"])

          write(slug, :facility_relationship, { organization_id: organization.id, facility_id: facility.id,
            relationship_type: item["type"], description: item["note"], ownership_pct: item["ownership_pct"] },
            evidence(item, sources), pending: item["pending"], hold: hold_reason(organization.id, facility.id, item))
        end
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
        return if Directory::Lookup.facility(name: entry["name"])

        former = Array(entry["other_names"]).lazy.filter_map { |name| Directory::Lookup.facility(name:) }.first or return
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
        facility = Directory::Lookup.facility(name:) or return

        FACILITY_FIELDS.each do |field|
          detail = entry[field]
          next unless detail.is_a?(Hash) && detail["value"].present?

          write("facilities.yml", :facility, { id: facility.id, field.to_sym => detail["value"] }, evidence(detail, sources))
        end
        if entry["other_names"].present?
          write("facilities.yml", :facility, { id: facility.id, aliases: entry["other_names"] }, [])
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

      def closed_link?(organization_id, facility_id, type)
        FacilityRelationship.find_by(organization_id:, facility_id:, relationship_type: type)&.closed?
      end

      def write(slug, kind, attributes, evidence, pending: false, hold: nil, remove_aliases: [])
        verification = hold ? { status: "pending", by: VERIFICATION[:by], reason: hold } : (VERIFICATION unless pending)
        result = Directory::FactWriter.write(kind, attributes, evidence: Array.wrap(evidence), verification:, remove_aliases:)
        if result.ok?
          count(kind, result.id, result.created ? :created : (result.changed ? :changed : :unchanged))
        else
          @errors << "#{slug}: #{kind} #{attributes[:name] || attributes[:role] || attributes[:relationship_type]}: " \
            "#{result.errors.join("; ")}"
        end
        result
      end
  end
end
