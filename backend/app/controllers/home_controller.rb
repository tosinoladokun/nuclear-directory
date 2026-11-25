# The home page (#41): one job, search. The wordmark, the search field with instant results and a card for each bucket
# with companies, plus Plants and sites, naming three of each (#362). The view builds the cards (cached per data version).
#
# The A/B test (#909) picks a version per visitor (HomeVariant); the page tells the analytics which one it is.
class HomeController < ApplicationController
  def show
    @home_variant = HomeVariant.pick(request, forced: params[:home], bot: bot?)
    # B: search and charts. Without a whole set of charts to show, the page stays A.
    @charts = HomeCharts.cards_for(request) if @home_variant.b?
    @home_variant = HomeVariant.new("A", forced: @home_variant.forced?) if @home_variant.b? && @charts.nil?
  end
end
