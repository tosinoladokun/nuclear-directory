# What Directory::Lookup returns for an organization: plain values, not a
# model, so callers can't reach into the database through it.
Directory::OrganizationRef = Data.define(:id, :slug, :name, :domain, :sec_cik, :verification_status, :verified_by, :verified_at) do
  def self.from(organization)
    new(**organization.slice(*members).symbolize_keys)
  end
end
