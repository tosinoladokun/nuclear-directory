# News items (#137 part B) are claims like any fact: found on a page,
# matched to the companies and plants they're about, checked, and approved
# by a person before they show in "Latest".
class AllowNewsItemCandidates < ActiveRecord::Migration[8.1]
  KINDS = %w[organization organization_alias organization_role organization_technology facility relationship facility_relationship].freeze

  def up
    remove_check_constraint :candidates, name: "candidates_kind_check"
    add_check_constraint :candidates, "kind IN (#{[ *KINDS, 'news_item' ].map { |kind| "'#{kind}'" }.join(', ')})", name: "candidates_kind_check"
  end

  def down
    remove_check_constraint :candidates, name: "candidates_kind_check"
    add_check_constraint :candidates, "kind IN (#{KINDS.map { |kind| "'#{kind}'" }.join(', ')})", name: "candidates_kind_check"
  end
end
