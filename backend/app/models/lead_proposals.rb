# Leads become new-company (or plant) proposals by themselves (#572, the
# owner, 26 Oct): a lead seen in an official source whose stored text names
# it becomes a claim on that source, quoting the line that names it. The
# next match proposes it as a pending record; it reaches Tosin's Today once
# it has a sourced category (#638), and nothing publishes without his Yes.
# Weaker leads (unofficial or no stored text) stay in the table. No role is
# ever guessed.
class LeadProposals
  # Government and registry sources whose stored text we read.
  OFFICIAL = %w[nrc_reactor_list nrc_power_status nrc_decommissioning nrc_uranium_recovery nrc_adams nrc_reactor_vendors
    nrc_research_reactors nrc_fuel_cycle usaspending_doe_awards usaspending_api doe_isotope_sites doe_nuclear_news doe_programs
    doe_loans arpa_e_projects sec_form_d sec_submissions federal_register_nrc federal_register_index eia_plants eia_owners
    eia_generators].freeze
  NOTE = "Proposed from a lead".freeze
  PER_NIGHT = 20
  BY = "agent:leads".freeze

  def self.run = new.run

  # Returns how many leads became proposals.
  def run
    Lead.where(status: %w[triage new], kind: %w[company plant]).order(:last_seen_on).limit(500).each.with_object([]) do |lead, made|
      break made if made.size >= PER_NIGHT

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
    end.size
  end

  private
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
      Source.where(source_kind: OFFICIAL).where(id: ids).or(Source.where(source_kind: OFFICIAL, url: urls)).where.not(content_text: [ nil, "" ]).find_each do |source|
        line = source.content_text.each_line.find { |text| text.downcase.include?(lead.name.downcase) }
        return [ source, line.squish.first(500) ] if line.present?
      end
      nil
    end
end
