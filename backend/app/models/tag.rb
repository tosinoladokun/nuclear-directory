# Tags with their own shareable list pages, /companies?tag=fusion (#281).
# A tag is finer than a bucket and never navigation: fusion sits under
# Developers, uranium and isotopes under Fuel and materials. Each
# is matched from a published, sourced technology or role (with its children).
# Data Quality's full public tag set comes with the filters (#263, #267). A title is at most 41 characters, so with
# " | Nuclear Directory" it stays within 60.
#
#   Tag.find("fusion").organization_ids # => a subquery of company ids
Tag = Data.define(:key, :name, :title, :about, :technology_key, :role_key) do
  def self.all = self::ALL
  def self.find(key) = self::ALL.find { |tag| tag.key == key.to_s }

  # The tag whose list a company's role or technology tag opens, when there is one (exact key, not its
  # children: a tag under a company's name links only to the list that is about that very thing).
  def self.for_role(key) = self::ALL.find { |tag| tag.role_key == key.to_s }
  def self.for_technology(key) = self::ALL.find { |tag| tag.technology_key == key.to_s }

  def initialize(key:, name:, title:, about:, technology_key: nil, role_key: nil)
    super
  end

  def to_param = key

  def description(count)
    "#{count.to_i > 1 ? "#{count} #{about}" : about.upcase_first}."
  end

  def organization_ids
    ids = if technology_key
      techs = Technology.where(key: technology_key)
      tech_ids = Technology.where(id: techs.select(:id)).or(Technology.where(parent_id: techs.select(:id))).select(:id)
      sourced(OrganizationTechnology.published.where(technology_id: tech_ids)).select(:organization_id)
    else
      roles = Role.where(key: role_key)
      role_ids = Role.where(id: roles.select(:id)).or(Role.where(parent_id: roles.select(:id))).select(:id)
      sourced(OrganizationRole.published.where(role_id: role_ids)).select(:organization_id)
    end
    Organization.published.where(id: ids).select(:id)
  end

  # A fact counts once it has a source, as on the company's page.
  def sourced(facts) = facts.where(id: Evidence.where(subject_type: facts.model.name).select(:subject_id))
end

class Tag
  ALL = [
    new(key: "fusion", name: "Fusion", technology_key: "fusion",
      title: "Fusion energy companies in the US",
      about: "fusion energy companies in the US"),
    new(key: "uranium", name: "Uranium", role_key: "mining",
      title: "Uranium mining and milling in the US",
      about: "companies mining and milling uranium in the US"),
    new(key: "isotopes", name: "Isotopes", role_key: "isotopes",
      title: "Isotope producers in the US",
      about: "companies producing medical and industrial isotopes in the US"),
    # #606: every role and technology finer than a category that a company page shows. A tag with no company yet
    # is neither linked nor in the sitemap.
    new(key: "smr", name: "Small modular reactors", technology_key: "smr",
      title: "SMR companies in the US",
      about: "small modular reactor (SMR) companies in the US"),
    new(key: "fission", name: "Fission", technology_key: "fission",
      title: "Fission energy companies in the US",
      about: "fission energy companies in the US"),
    new(key: "enrichment", name: "Enrichment", role_key: "enrichment",
      title: "Uranium enrichment companies in the US",
      about: "uranium enrichment companies in the US"),
    new(key: "conversion", name: "Conversion", role_key: "conversion",
      title: "Uranium conversion companies in the US",
      about: "uranium conversion companies in the US"),
    new(key: "fuel-fabrication", name: "Fuel fabrication", role_key: "fabrication",
      title: "Nuclear fuel fabrication companies",
      about: "nuclear fuel fabrication companies in the US"),
    new(key: "national-labs", name: "National labs", role_key: "national_lab",
      title: "National laboratories in nuclear energy",
      about: "national laboratories in the US nuclear industry"),
    new(key: "universities", name: "Universities", role_key: "university",
      title: "Universities in nuclear energy",
      about: "universities in the US nuclear industry"),
    new(key: "venture-capital", name: "Venture capital", role_key: "venture_capital",
      title: "Nuclear venture capital investors",
      about: "venture capital investors in US nuclear energy"),
    new(key: "data-center-buyers", name: "Data center buyers", role_key: "data_center_offtaker",
      title: "Data centers buying nuclear power",
      about: "data center companies buying nuclear power in the US"),
    new(key: "research-organizations", name: "Research organizations", role_key: "research_organization",
      title: "Nuclear research organizations in the US",
      about: "nuclear research organizations in the US"),
    new(key: "regulatory-consultants", name: "Regulatory consultants", role_key: "regulatory_consultant",
      title: "Nuclear regulatory consultants in the US",
      about: "nuclear regulatory consultants in the US")
  ].freeze
end
