# A DirectoryClient for one page that reads many claims at once (Tosin's
# inbox, #1008): the records the claims are about, and which companies have a
# sourced role, are read up front in a few queries, so asking about each claim
# doesn't query again. Anything it wasn't given is asked of the directory as
# usual. Only for reading: a write isn't seen by what was read before it.
class DataQuality::PrefetchedDirectory < SimpleDelegator
  def initialize(directory = DataQuality::DirectoryClient.new)
    super
    @facts = {}
    @attached = {}
    @sourced_roles = {}
  end

  # Reads the subjects of these claims, and the sourced roles of the companies among them.
  def prefetch(candidates)
    by_type = candidates.select(&:subject_id).group_by(&:subject_type)
    by_type.each do |type, claims|
      next unless fact_kinds.include?(type.to_s.underscore)

      ids = claims.map(&:subject_id).uniq - @facts.fetch(type, {}).keys
      found = __getobj__.facts(type:, ids:)
      (@facts[type] ||= {}).merge!(ids.index_with { |id| found[id] })
      next unless %w[Organization Facility].include?(type)

      ids = claims.map(&:subject_id).uniq - @attached.fetch(type, {}).keys
      found = __getobj__.attached_records(type:, ids:)
      (@attached[type] ||= {}).merge!(ids.index_with { |id| found[id] })
    end
    companies = by_type.fetch("Organization", []).map(&:subject_id).uniq - @sourced_roles.keys
    with_role = __getobj__.sourced_role_ids(companies)
    companies.each { |id| @sourced_roles[id] = with_role.include?(id) }
    self
  end

  def fact(type:, id:)
    cached = @facts[type.to_s]
    cached&.key?(id) ? cached[id] : __getobj__.fact(type:, id:)
  end

  def attached_record(candidate)
    return unless candidate.subject_id
    # A link, role or term is its fact, as the directory reads it; read through this cache (Copilot).
    return fact(type: candidate.subject_type, id: candidate.subject_id) unless %w[Organization Facility].include?(candidate.subject_type)

    cached = @attached[candidate.subject_type.to_s]
    cached&.key?(candidate.subject_id) ? cached[candidate.subject_id] : __getobj__.attached_record(candidate)
  end

  def sourced_role?(organization_id)
    @sourced_roles.key?(organization_id) ? @sourced_roles[organization_id] : __getobj__.sourced_role?(organization_id)
  end
end
