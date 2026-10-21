# Search gaps (#483): what visitors searched for and didn't find, most
# searched first, for the admin to mark Research, Covered or Ignore. A gap
# closes on its own once the same search finds something.
class Admin::SearchGapsController < Admin::BaseController
  def index
    @waiting = SearchGap.waiting.order(searches_count: :desc, last_searched_on: :desc, id: :desc).limit(200)
    @decided = SearchGap.where(status: %w[covered ignored closed]).order(updated_at: :desc).limit(50)
  end

  def decide
    gap = SearchGap.find(params[:id])
    gap.decide!(params[:decision], by: actor)
    flash[:notice] = "“#{gap.query}”: #{{ 'research' => 'marked to research', 'covered' => 'marked covered', 'ignored' => 'ignored' }.fetch(params[:decision])}."
    redirect_after admin_search_gaps_path(anchor: "gap-#{gap.id}")
  end
end
