# Tags with their own shareable list pages, /companies?tag=fusion (#281).
# A tag is finer than a bucket and never navigation: fusion sits under
# Developers, uranium and isotopes under Fuel and materials. Each
# is matched from a published, sourced technology or role (with its children).
# Data Quality's full public tag set comes with the filters (#263, #267).
#
#   Tag.find("fusion").organization_ids # => a subquery of company ids
Tag = Data.define(:key, :name, :title, :about, :technology_key, :role_key) do
  def self.all = self::ALL
  def self.find(key) = self::ALL.find { |tag| tag.key == key.to_s }

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
      title: "Uranium mining and milling companies in the US",
      about: "companies mining and milling uranium in the US"),
    new(key: "isotopes", name: "Isotopes", role_key: "isotopes",
      title: "Medical and industrial isotope producers in the US",
      about: "companies producing medical and industrial isotopes in the US")
  ].freeze
end
