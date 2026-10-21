# Removed (#166): every company, plant and link off the site now (taken
# off, merged or rejected), newest first, with the reason, who and when.
# Put back goes through the fact page's action (FactsController#republish).
class Admin::RemovedController < Admin::BaseController
  def show
    @list = Directory::RemovedList.new(tab: params[:tab].to_s)
    @page = [ params[:page].to_i, 1 ].max
    @rows = @list.page(@page)
  end
end
