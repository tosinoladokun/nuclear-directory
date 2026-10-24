# Deal terms become a claim kind (#397), so a crawler can propose a funding
# round or an award for a person to approve. Adds deal_term to whatever kinds
# the constraint allows when it runs, and takes only it away on rollback, so
# it composes with other PRs that add kinds (news_item, #497; Enrich, #506)
# in any merge order.
class AllowDealTermCandidates < ActiveRecord::Migration[8.1]
  KIND = "deal_term"

  def up = replace(current_kinds | [ KIND ])

  def down = replace(current_kinds - [ KIND ])

  private
    def current_kinds
      definition = select_value("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'candidates_kind_check'").to_s
      definition.scan(/'([a-z_]+)'/).flatten.uniq
    end

    def replace(kinds)
      remove_check_constraint :candidates, name: "candidates_kind_check"
      add_check_constraint :candidates, "kind IN (#{kinds.map { |kind| connection.quote(kind) }.join(', ')})", name: "candidates_kind_check"
    end
end
