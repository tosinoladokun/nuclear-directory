# The middle column of a company list row (#559): its short description, or,
# until Data Quality writes one, role · specialty from what's published:
# the role that puts it in this list's category first, then a technology or
# its next role. "Small modular reactor" reads "SMR"; "Fission" alone is too
# broad to say anything. Built for a whole list at once, never per row.
#
#   ShortDescription.for(companies, category: Category.find("fuel"))
#   # => { 12 => "Uranium enrichment, including HALEU", 40 => "Enrichment · Isotope producer" }
module ShortDescription
  MAX = 40
  TECHNOLOGY_WORDS = { "Small modular reactor" => "SMR" }.freeze
  TOO_BROAD = %w[fission].freeze

  def self.for(organizations, category: nil)
    organizations = organizations.to_a
    ids = organizations.map(&:id)
    # Published and sourced only, as the company page and the buckets show them.
    roles = sourced(OrganizationRole.published.where(organization_id: ids)).includes(role: :parent).order(:id).group_by(&:organization_id)
    technologies = sourced(OrganizationTechnology.published.where(organization_id: ids)).includes(:technology).order(:id).group_by(&:organization_id)
    # A written one shows only when the company has evidence of its own, as CompanyProfile's description.
    backed = Evidence.where(subject_type: "Organization", subject_id: ids).distinct.pluck(:subject_id).to_set
    organizations.to_h do |organization|
      [ organization.id, (organization.short_description.presence if backed.include?(organization.id)) ||
        fallback(Array(roles[organization.id]).map(&:role), Array(technologies[organization.id]).map(&:technology), category) ]
    end
  end

  def self.fallback(roles, technologies, category)
    in_category = roles.find { |role| category && ([ role.key, role.parent&.key ] & category.role_keys).any? }
    first = in_category || roles.first
    second = technologies.reject { |technology| TOO_BROAD.include?(technology.key) }.map { |technology| TECHNOLOGY_WORDS.fetch(technology.name, technology.name) }.first ||
      (roles - [ first ]).map { |role| role_label(role) }.find { |label| label != (first && role_label(first)) }
    # Within the same 40 as a written one: the specialty goes first, then nothing.
    [ [ (role_label(first) if first), second ], [ (role_label(first) if first) ] ].each do |parts|
      line = parts.compact.uniq.join(" · ")
      return line.presence if line.length <= MAX
    end
    nil
  end

  def self.sourced(facts) = facts.where(id: Evidence.where(subject_type: facts.model.name).select(:subject_id))

  def self.role_label(role) = DirectoryHelper::ROLE_LABELS.fetch(role.key, role.name)
end
