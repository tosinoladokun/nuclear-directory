# The lead pipeline's entry point (Backend's LeadFindJob, #755): a lead in,
# the lead finder's Outcome out. Only the lead's id crosses into DataQuality.
module DataQuality::LeadFinder
  def self.call(lead, finder: DataQuality::Plugins::LeadFinder.new)
    DataQuality::Plugins::LeadFinder.call(lead.respond_to?(:id) ? lead.id : lead, finder:)
  end
end
