namespace :directory do
  desc "Keep the old slugs of plants and companies renamed or merged before #143 (one-off, safe to rerun)"
  task backfill_former_slugs: :environment do
    kept = []
    # A rename a human made is in the audit trail as a slug change.
    VerificationEvent.where(subject_type: %w[Facility Organization]).where("changed_values ? 'slug'").find_each do |event|
      old = Array(event.changed_values["slug"]).first
      record = event.subject_type.constantize.find_by(id: event.subject_id) or next
      next if old.blank? || old == record.slug || record.class.exists?(slug: old) || record.former_slugs.exists?(slug: old)

      record.remember_slug(old) && kept << "#{event.subject_type} #{old} -> #{record.slug}"
    end
    # A merged company's unpublish reason names the company it went into.
    Organization.unpublished.find_each do |merged|
      into_id = merged.verification_events.order(:id).last&.reason.to_s[/Merged into .+? \(#(\d+)\)/, 1] or next
      into = Organization.find_by(id: into_id) or next
      next if into.former_slugs.exists?(slug: merged.slug)

      into.remember_slug(merged.slug) && kept << "Organization #{merged.slug} -> #{into.slug}"
    end
    puts kept.any? ? kept : "Nothing to backfill."
  end

  # Merges one plant site or company into another (#229), as the named
  # person. Without APPLY=1 it's a dry run: the merge runs, prints what it
  # would move, and is rolled back.
  merge = lambda do |model, method, args|
    by = ENV["BY"].to_s
    apply = ENV["APPLY"] == "1"
    from_id, into_id = args[:from].to_s, args[:into].to_s
    abort "Usage: BY=human:<handle> [APPLY=1] bin/rails \"directory:#{method}[from_id,into_id]\"" unless
      by.match?(/\Ahuman:\S+\z/) && [ from_id, into_id ].all? { |id| id.match?(/\A\d+\z/) }

    names = model.where(id: [ from_id, into_id ]).pluck(:id, :name).to_h
    ActiveRecord::Base.transaction(requires_new: true) do
      result = Directory::FactWriter.public_send(method, from_id: from_id.to_i, into_id: into_id.to_i, by:, reason: ENV["REASON"].presence)
      abort "#{names[from_id.to_i] || from_id} -> #{names[into_id.to_i] || into_id}: #{result.errors.to_sentence}" unless result.ok?

      moved = VerificationEvent.where(subject_type: model.name, subject_id: from_id.to_i).order(:id).last.reason
      puts "#{apply ? 'Merged' : 'Would merge'} #{names[from_id.to_i]} (##{from_id}) into #{names[into_id.to_i]} (##{into_id}): #{moved}"
      raise ActiveRecord::Rollback unless apply
    end
    puts "Dry run: nothing changed. Add APPLY=1 to merge." unless apply
  end

  desc "Merge a duplicate plant site into the one kept, audited: BY=human:tosin [APPLY=1] bin/rails \"directory:merge_facility[173,13]\""
  task :merge_facility, %i[from into] => :environment do |_task, args|
    merge.call(Facility, :merge_facility, args)
  end

  desc "Merge a duplicate company into the one kept, audited: BY=human:tosin [APPLY=1] bin/rails \"directory:merge_organization[80,34]\""
  task :merge_organization, %i[from into] => :environment do |_task, args|
    merge.call(Organization, :merge_organization, args)
  end

  # EIA's Entity Name is the utility that reports a generator, not the
  # plant's operator (#227). Published "operates" links whose only evidence
  # is EIA's are listed. With BY=human:<name> APPLY=1, the ones whose plant
  # has a published operator from NRC's list are unpublished,
  # each recorded with who did it and why; the rest are left for a person.
  desc "List the published operates links only EIA backs; BY=human:<name> APPLY=1 [SKIP=id,…] unpublishes those another operator contradicts (#227)"
  task retire_eia_operators: :environment do
    by = ENV["BY"].to_s
    apply = ENV["APPLY"] == "1"
    abort "APPLY=1 needs BY=human:<name>" if apply && !by.match?(/\Ahuman:\S+\z/)
    # Links a person decided to keep, e.g. SKIP=169 (Perry: NRC's row still
    # names a company retired in 2020, #237). Listed, never changed.
    skip = ENV["SKIP"].to_s.split(",").map(&:strip)
    abort "SKIP takes link ids: SKIP=169,170" unless skip.all? { |id| id.match?(/\A\d+\z/) }
    skip = skip.map(&:to_i)

    backed_by = ->(kind) { Evidence.joins(:source).where(subject_type: "FacilityRelationship", sources: { source_kind: kind }).select(:subject_id) }
    other = Evidence.joins(:source).where(subject_type: "FacilityRelationship").where.not(sources: { source_kind: "eia_generators" }).select(:subject_id)
    links = FacilityRelationship.published.where(relationship_type: "operates", id: backed_by["eia_generators"]).where.not(id: other)
      .includes(:organization, :facility)
    reason = "EIA's Entity Name is the utility that reports the generator, not the plant's operator (#227)"

    found = links.map do |link|
      site = link.facility.parent || link.facility
      plant = [ site.id, *Facility.where(parent_id: site.id).ids ]
      # Only a current, published operator that NRC's list backs counts
      # against EIA's (an ended one isn't shown as current, PlantProfile#links).
      operators = FacilityRelationship.published.where(relationship_type: "operates", facility_id: plant, id: backed_by["nrc_reactor_list"])
        .where("facility_relationships.ended_on IS NULL OR facility_relationships.ended_on > ?", Date.current)
        .where.not(id: link.id).where.not(organization_id: link.organization_id).includes(:organization).map { |o| o.organization.name }.uniq
      line = "FacilityRelationship #{link.id}: #{link.organization.name} operates #{link.facility.name}"
      if operators.empty?
        "#{line} (no published NRC operator; check by hand)"
      elsif skip.include?(link.id)
        "#{line} -> kept (SKIP; #{operators.join(', ')})"
      elsif apply
        result = DataQuality::Review.unpublish(type: "FacilityRelationship", id: link.id, by:, reason:)
        "#{line} -> #{result.errors.empty? ? 'unpublished' : "not unpublished: #{result.errors.join('; ')}"} (#{operators.join(', ')})"
      else
        "#{line} -> would unpublish (#{operators.join(', ')})"
      end
    end
    puts found.any? ? found : "No published operates links rest on EIA alone."
  end

  # Awards #260 stored before deal terms existed (#256): each DOE "funds"
  # link sums its awards in its description; this writes one award term per
  # award, from the rows on that link's own sources (the recipient pages), never
  # by name. A term is verified only if a human verified its link; otherwise it
  # waits with the link. Re-running finds each term by its award ID.
  desc "Write award deal terms from stored USAspending rows, audited: BY=human:<name> [APPLY=1] (#256)"
  task backfill_award_terms: :environment do
    by = ENV["BY"].to_s
    abort "Usage: BY=human:<handle> [APPLY=1] bin/rails directory:backfill_award_terms" unless by.match?(/\Ahuman:\S+\z/)

    apply = ENV["APPLY"] == "1"
    counts = Hash.new(0)
    # Every company merged into this one, at any depth (A into B, then B into C).
    merged_into = ->(company_id) do
      found = []
      frontier = [ company_id ]
      while frontier.any?
        frontier = VerificationEvent.where(subject_type: "Organization", to_status: "unpublished")
          .where("context -> 'merged_into' ->> 'id' IN (?)", frontier.map(&:to_s)).pluck(:subject_id) - found
        found += frontier
      end
      found
    end
    Relationship.where(relationship_type: "funds").where.not(verification_status: Verifiable::CLOSED_STATUSES).order(:id).each do |link|
      # Its own sources, and those of a funds link between companies merged
      # into either end (funder or recipient), but only a link the merge itself retired: its last
      # decision is the merge's rejection ("Merged into …", #229). A link a
      # person closed before the merge stays closed, and its rows aren't read.
      funders = [ link.from_organization_id, *merged_into.(link.from_organization_id) ]
      recipients = [ link.to_organization_id, *merged_into.(link.to_organization_id) ]
      retired = Relationship.where(from_organization_id: funders, to_organization_id: recipients,
        relationship_type: "funds", verification_status: "rejected").where.not(id: link.id).select do |other|
        other.verification_events.order(:id).last&.reason.to_s.match?(/Merged into .+ \(#\d+\)/)
      end
      links = [ link, *retired ]
      sources = Source.where(source_kind: "usaspending_doe_awards", id: Evidence.where(subject: links).select(:source_id))
      sources.each do |source|
        CSV.parse(source.content_text, headers: true).each do |row|
          next if row["generated_award_id"].blank?

          # Already handled when any of these links has it, in any state: a
          # term a person rejected isn't written again on the kept link.
          existing = DealTerm.where(link: links, term_type: "award", external_id: row["generated_award_id"]).exists?
          next counts[:already] += 1 if existing

          counts[:written] += 1
          next unless apply

          verification = { status: "verified", by:, reason: "Backfilled from its link's USAspending rows (#256)" } if link.human_verified?
          result = Directory::FactWriter.write(:deal_term, {
            link_type: "Relationship", link_id: link.id, term_type: "award", external_id: row["generated_award_id"],
            amount_usd: row["amount_usd"], starts_on: row["start_date"], ends_on: row["end_date"].presence,
            program: row["assistance_listing"].presence || row["award_type"]
          }, evidence: [ { source_id: source.id, quote: row.to_csv.chomp, found_by: "crawler" } ], verification:,
            # Locks the link and refuses it if a merge closed it since it was
            # read, so a rerun writes onto the link the merge kept.
            protect_human_verified: true)
          next if result.ok?

          counts[:written] -= 1
          counts[:failed] += 1
          puts "link #{link.id}, award #{row["generated_award_id"]}: #{result.errors.join('; ')}"
        end
      end
    end
    verb = apply ? "written" : "would be written"
    puts "#{counts[:written]} award terms #{verb}, #{counts[:already]} already there#{", #{counts[:failed]} failed" if counts[:failed].positive?}."
    puts "Dry run: nothing changed. Run again with APPLY=1 to apply." unless apply
  end

  # Merges before #166 recorded where a record went only in their reason
  # ("… Merged into Urenco (#41). Moved: …"). This adds the same, structured,
  # to those events' context ({ "merged_into" => { "type", "id" } }), as
  # merges now write it. Only a merged-away record's own event counts: an
  # Organization or Facility going to unpublished. A fact a merge retired
  # (rejected) and the kept record's events aren't merges into anything.
  desc "Record merged_into on past merge events from their reasons, audited: BY=human:<name> [APPLY=1] (#166)"
  task backfill_merged_into: :environment do
    by = ENV["BY"].to_s
    abort "Usage: BY=human:<handle> [APPLY=1] bin/rails directory:backfill_merged_into" unless by.match?(/\Ahuman:\S+\z/)

    apply = ENV["APPLY"] == "1"
    events = VerificationEvent.where(subject_type: %w[Organization Facility], to_status: "unpublished")
      .where("reason ~ ?", 'Merged into .+ \(#[0-9]+\)').where("NOT (context ? 'merged_into')").order(:id)
    skipped = 0
    found = events.map do |event|
      into_id = event.reason[/Merged into .+? \(#(\d+)\)/, 1].to_i
      into = event.subject_type.constantize.find_by(id: into_id)
      line = "event #{event.id}: #{event.subject_type} #{event.subject_id} -> #{into&.name || 'missing'} (##{into_id})"
      unless into
        skipped += 1
        next "#{line}: skipped, no #{event.subject_type} ##{into_id}"
      end

      if apply
        # Verification events are append-only (VerificationEvent#before_update).
        # This one-off adds a key to the context and changes nothing else, so
        # it writes past the model on purpose, recording who did it.
        added = { "merged_into" => { "type" => event.subject_type, "id" => into_id }, "merged_into_backfilled_by" => by }
        VerificationEvent.where(id: event.id).update_all([ "context = context || ?::jsonb", added.to_json ])
      end
      line
    end
    puts found.any? ? found : "No merge events without merged_into."
    puts "#{found.size - skipped} #{apply ? 'recorded' : 'would be recorded'}#{", #{skipped} skipped" if skipped.positive?}." if found.any?
    puts "Dry run: nothing changed. Run again with APPLY=1 to apply." unless apply || found.empty?
  end

  # Sets plants' or units' status as a person's decision, quoting NRC's
  # 365-day power status file: human-verified, so a crawler can't change it
  # back, only propose a change in Checks. Without APPLY=1 it's a dry run:
  # it prints what would change and writes nothing. The quote is the file's
  # newest line naming the first facility ("10/14/2026 12:00:00 AM|Palisades|0"),
  # or QUOTE=… (it must be in the file as last fetched). The admin's Change
  # status does the same (Directory::StatusChange, #316).
  desc "Set plants' or units' status from NRC's status file, audited: BY=human:tosin [APPLY=1] bin/rails \"directory:set_status[not_operating,171 174]\""
  task :set_status, %i[status ids] => :environment do |_task, args|
    by = ENV["BY"].to_s
    apply = ENV["APPLY"] == "1"
    status = args[:status].to_s
    abort "Usage: BY=human:<handle> [APPLY=1] [QUOTE=…] bin/rails \"directory:set_status[status,id id …]\"" unless
      by.match?(/\Ahuman:\S+\z/) && Facility.statuses.key?(status) && args[:ids].present?

    plan = Directory::StatusChange.plan(ids: args[:ids], status:)
    first = Facility.find(args[:ids].split.first.to_i)
    source = Directory::StatusChange.nrc_status_file or abort "NRC's status file hasn't been fetched"
    quote = ENV["QUOTE"].presence || Directory::StatusChange.nrc_quote(first.name)&.last
    abort "#{first.name} isn't in NRC's status file; give QUOTE=…" if quote.blank?
    abort "The quote isn't in NRC's status file as last fetched: #{quote}" unless source.content_text.to_s.include?(quote)

    reason = ENV["REASON"].presence || "NRC's 365-day power status file: #{quote}"
    plan = Directory::StatusChange.apply(ids: args[:ids], status:, by:, reason:, source_id: source.id, quote:) if apply
    plan.unchanged.each { |same| puts "#{same.name} (##{same.id}) is already #{status}; nothing to change" }
    plan.changes.each do |change|
      puts "#{apply ? 'Set' : 'Would set'} #{change.name} (##{change.id}): #{change.from || 'blank'} -> #{status}, quoting \"#{quote}\""
    end
    puts "Dry run: nothing changed. Add APPLY=1 to set it." unless apply
  rescue Directory::StatusChange::Invalid => error
    abort error.message
  end
end
