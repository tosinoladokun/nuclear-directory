# News items (#137 part B) are claims like any fact: found on a page,
# matched to the companies and plants they're about, checked, and approved
# by a person before they show in "Latest". Adds news_item to whatever kinds
# the constraint allows when it runs, and takes only it away on rollback, so
# it composes with other PRs that add kinds (deal_term, #401) in any merge
# order. Rollback fails while news_item claims exist, which is intended.
class AllowNewsItemCandidates < ActiveRecord::Migration[8.1]
  KIND = "news_item"

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
