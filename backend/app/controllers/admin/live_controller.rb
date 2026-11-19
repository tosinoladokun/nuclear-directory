# Live (#201 part 2): every record of a tab (companies, plants, reactors,
# links), searched and narrowed by Data Quality's tags (#238), each chip
# with its count. Everything chosen is in the URL, so Back and Forward work
# and a view can be bookmarked.
class Admin::LiveController < Admin::BaseController
  def show
    @list = live_list(params)
    @page = [ params[:page].to_i, 1 ].max
    @rows = @list.page(@page)
    @tab_counts = Directory::LiveList.tab_counts(status: @list.chosen["status"].first, within: @list.within)
  end

  # The list described by a Live URL's parameters (also for Previous and
  # Next on a record opened from it).
  def self.list_for(params)
    chosen = Directory::Checks::GROUPS.keys.index_with { |group| params[group].to_s.split(",").map(&:strip).compact_blank }
    Directory::LiveList.new(tab: params[:tab].to_s, query: params[:q], chosen:, within: params[:within].presence)
  end

  private
    def live_list(params) = self.class.list_for(params)
end
