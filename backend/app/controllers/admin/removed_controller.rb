# Removed (#166): every company, plant and link off the site now (taken
# off, merged or rejected), newest first, with the reason, who and when.
# Put back goes through the fact page's action (FactsController#republish).
class Admin::RemovedController < Admin::BaseController
  def show
    @list = Directory::RemovedList.new(tab: params[:tab].to_s)
    # Clamped to the last page: putting back the only row on it leaves one less page.
    last = [ (@list.total / Directory::RemovedList::PAGE.to_f).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, last)
    @rows = @list.page(@page)
  end
end
