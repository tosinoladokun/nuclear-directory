# Tosin's "Suggest a company" (#752; Backend's CompanySuggestionJob, #755):
# the raw text he typed and its lead, through the one lead finder.
module DataQuality::CompanySuggestion
  def self.call(input, lead_id:, finder: DataQuality::Plugins::LeadFinder.new)
    DataQuality::Plugins::LeadFinder.call(lead_id, finder:, input:)
  end
end
