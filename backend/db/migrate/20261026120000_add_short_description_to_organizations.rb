# Short labels (#559, Design 4.2): a company's short description, the middle
# column of every company list row, and a link's short phrase, a deal row's
# "what" when it has no deal terms ("LEU and HALEU enrichment"). Both
# nullable and 40 characters at most, also checked here. Until written,
# rows show role · specialty, and a link row shows name and verb only.
class AddShortDescriptionToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :short_description, :string
    add_check_constraint :organizations, "char_length(short_description) <= 40", name: "organizations_short_description_length"
    %i[relationships facility_relationships].each do |table|
      add_column table, :short_phrase, :string
      add_check_constraint table, "char_length(short_phrase) <= 40", name: "#{table}_short_phrase_length"
    end
  end
end
