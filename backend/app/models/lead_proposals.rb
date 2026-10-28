# Leads become new-company (or plant) proposals by themselves (#572, the
# owner, 26 Oct): a lead seen in an official source whose stored text names
# it becomes a claim on that source, quoting the line that names it. The
# next match proposes it as a pending record; it reaches Tosin's Today once
# it has a sourced category (#638), and nothing publishes without his Yes.
# Weaker leads (unofficial or no stored text) stay in the table. No role is
# ever guessed.
class LeadProposals
  # Government and registry sources whose stored text we read.
  # Only kinds with a plug-in, so their claims are matched and verified.
  OFFICIAL = %w[nrc_reactor_list nrc_decommissioning nrc_uranium_recovery nrc_adams nrc_reactor_vendors
    nrc_research_reactors nrc_fuel_cycle usaspending_doe_awards doe_isotope_sites doe_nuclear_news doe_programs
    doe_loans arpa_e_projects sec_form_d federal_register_nrc eia_plants eia_owners eia_generators].freeze
  # Characters quoted either side of the name.
  AROUND = 200
  NOTE = "Proposed from a lead".freeze
  PER_NIGHT = 20
  BY = "agent:leads".freeze

  def self.run = new.run

  # Returns how many leads became proposals.
  def run
    made = []
    # Every eligible lead in turn, so ineligible ones never block newer ones.
    Lead.where(status: %w[triage new], kind: %w[company plant]).order(:last_seen_on, :id).find_each(batch_size: 200) do |lead|
      break if made.size >= PER_NIGHT

      found = official_line(lead) or next
      source, line = found
      kind = lead.kind == "plant" ? "facility" : "organization"
      name = display_name(source, lead.name)
      # Only a name the directory doesn't have yet (DQ): a known one would be a pointless claim.
      next if known?(kind, name) || known?(kind, lead.name)
      next if Candidate.where(kind:, status: %w[new matched needs_review]).where("candidates.payload->>'name' IN (?)", [ name, lead.name ]).exists?

      payload = { "name" => name }
      payload["aliases"] = [ lead.name ] unless lead.name.casecmp?(name)
      Candidate.create!(source:, kind:, status: "new", payload:, quote: line,
        notes: "#{NOTE}: named in #{source.source_kind}")
      lead.decide!("researching", by: BY)
      made << lead.id
    end
    made.size
  end

  private
    # The source's own check, as verify will ask it.
    def quote_in_source?(source, quote)
      DataQuality::Plugin.for(source.source_kind).quote_in_source?(source, quote)
    rescue DataQuality::Plugin::UnknownSourceKind
      false
    end

    def known?(kind, name)
      kind == "facility" ? Directory::Lookup.facility(name:).present? : Directory::Lookup.organization(name:).present?
    end

    # The name as people read it: an award's registry spelling ("SAWTOOTH
    # SIMULATION, LLC") through its plug-in's display_name, as its own claims are.
    def display_name(source, spelling)
      plugin = DataQuality::Plugin.for(source.source_kind)
      plugin.respond_to?(:display_name) ? plugin.display_name(spelling) : spelling
    rescue DataQuality::Plugin::UnknownSourceKind
      spelling
    end

    # The first official source of the lead whose stored text names it, and that line.
    def official_line(lead)
      ids = lead.sources.filter_map { |entry| entry["key"].to_s[/\Aawards:(\d+)\z/, 1]&.to_i }
      urls = lead.sources.filter_map { |entry| entry["url"].presence }
      sources = Source.where(source_kind: OFFICIAL).where(id: ids).or(Source.where(source_kind: OFFICIAL, url: urls)).where.not(content_text: [ nil, "" ])
      # An award source not yet extracted is waiting for its night (the
      # recipients cap); extraction will claim it itself.
      sources = sources.where("sources.source_kind <> 'usaspending_doe_awards' OR sources.extracted_sha256 IS NOT NULL")
      named = /(?<![[:alnum:]])#{Regexp.escape(lead.name)}(?![[:alnum:]])/i
      sources.find_each do |source|
        source.content_text.each_line do |text|
          line = text.squish
          match = line.match(named) or next
          # A bounded passage around the name, so the quote always names it.
          from = [ match.begin(0) - AROUND, 0 ].max
          quote = line[from, match.end(0) - from + AROUND]
          return [ source, quote ] if quote_in_source?(source, quote)
        end
      end
      nil
    end
end
