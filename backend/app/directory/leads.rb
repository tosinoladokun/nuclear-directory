# Leads (#484) as Data Quality reaches them, through DirectoryClient: a name
# it closed as a claim is kept as a lead, never thrown away (#548).
module Directory::Leads
  def self.keep(name:, key:, label:, url: nil) = Lead.sighted!(name:, kind: "company", key:, label:, url:)
end
