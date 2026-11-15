# Leads (#484) as Data Quality reaches them, through DirectoryClient: a name
# it closed as a claim is kept as a lead, never thrown away (#548).
module Directory::Leads
  def self.keep(name:, key:, label:, url: nil) = Lead.sighted!(name:, kind: "company", key:, label:, url:)

  LeadRef = Data.define(:id, :name, :kind, :urls, :keys)
  # A lead as the lead finder reads it: its name, its sightings' links and keys.
  def self.find(id)
    lead = Lead.find_by(id:) or return
    LeadRef.new(id: lead.id, name: lead.name, kind: lead.kind, urls: lead.sources.filter_map { |source| source["url"].presence },
      keys: lead.sources.filter_map { |source| source["key"].presence })
  end
end
