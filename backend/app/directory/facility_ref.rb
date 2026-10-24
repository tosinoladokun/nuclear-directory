# What Directory::Lookup returns for a facility: plain values, not a model.
Directory::FacilityRef = Data.define(:id, :slug, :name, :nrc_docket, :eia_plant_id, :parent_id, :verification_status, :verified_by,
  :verified_at, :facility_type, :status, :city, :state, :country_code, :latitude, :longitude) do
  def self.from(facility)
    new(**facility.slice(*members).symbolize_keys)
  end
end
