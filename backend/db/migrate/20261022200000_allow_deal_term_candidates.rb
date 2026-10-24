# Deal terms become a claim kind (#397), so a crawler can propose a funding
# round or an award for a person to approve.
class AllowDealTermCandidates < ActiveRecord::Migration[8.1]
  BEFORE = %w[organization organization_alias organization_role organization_technology facility relationship facility_relationship].freeze
  AFTER = (BEFORE + %w[deal_term]).freeze

  def up
    remove_check_constraint :candidates, name: "candidates_kind_check"
    add_check_constraint :candidates, in_list(AFTER), name: "candidates_kind_check"
  end

  def down
    remove_check_constraint :candidates, name: "candidates_kind_check"
    add_check_constraint :candidates, in_list(BEFORE), name: "candidates_kind_check"
  end

  private
    def in_list(values) = "kind IN (#{values.map { |value| "'#{value}'" }.join(', ')})"
end
