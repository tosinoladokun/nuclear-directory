# What Directory::Lookup returns for a deal term (#256): plain values, not a
# model. source_urls: the sources it's cited to.
Directory::DealTermRef = Data.define(:id, :link_type, :link_id, :term_type, :external_id, :amount_usd, :amount_offered_usd, :capacity_mw, :signed_on,
  :starts_on, :ends_on, :status, :program, :round, :lead_investor_ids, :verification_status, :source_urls) do
  def self.from(term)
    new(**term.slice(*(members - [ :source_urls ])).symbolize_keys, source_urls: term.evidence.map { |row| row.source.url }.uniq)
  end
end
