# A company with its SEC CIK (#129), for a crawler that reads its filings:
# plain values, not a model.
Directory::SecFilerRef = Data.define(:id, :name, :sec_cik) do
  def self.from(organization) = new(id: organization.id, name: organization.name, sec_cik: organization.sec_cik)
end
