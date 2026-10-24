# What Directory::Lookup returns for a licensing stage (#379): plain values,
# not a model. source_urls: the sources it's cited to.
Directory::LicensingStageRef = Data.define(:id, :facility_id, :organization_id, :design_name, :stage, :nrc_docket,
  :effective_on, :expires_on, :verification_status, :source_urls) do
  def self.from(stage)
    new(**stage.slice(*(members - [ :source_urls ])).symbolize_keys, source_urls: stage.evidence.map { |row| row.source.url }.uniq)
  end

  # The stage in the words the issue uses ("Construction permit").
  def stage_label = LicensingStage::STAGE_LABELS.fetch(stage, stage.to_s.humanize)
end
