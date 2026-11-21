# News items (#863): a small data fix without a data-step PR. Find an item,
# edit its headline, summary or date with a reason (recorded in its
# history), and undo the last edit. Its status isn't changed here.
class Admin::NewsItemsController < Admin::BaseController
  before_action :load_item, except: :index

  def index
    @items = directory.news_items(q: params[:q].to_s.strip.presence)
  end

  def show
    @history = directory.news_history(@item["id"])
  end

  def edit; end

  def update
    values = params.fetch(:values, {}).permit(*DataQuality::Review::NEWS_EDITABLE).to_h
    result = DataQuality::Review.edit_news(id: @item["id"], by: actor, reason: params[:note].to_s.strip, attributes: values)
    if result.ok?
      flash[:notice] = "Saved."
      redirect_after admin_news_item_path(id: @item["id"])
    else
      @errors = result.errors
      render :edit, status: :unprocessable_entity
    end
  end

  def undo
    result = DataQuality::Review.undo_news_edit(id: @item["id"], by: actor)
    flash[result.ok? ? :notice : :alert] = result.ok? ? "Last edit undone." : result.errors.to_sentence.upcase_first
    redirect_after admin_news_item_path(id: @item["id"])
  end

  private
    def directory = @directory ||= DataQuality::DirectoryClient.new

    def load_item
      @item = directory.news_item(params[:id].to_i) or raise ActiveRecord::RecordNotFound
    end
end
