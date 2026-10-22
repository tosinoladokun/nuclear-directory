# Publish (#202): a company or plant site that isn't public yet, from its
# Record page. The preview says where it will appear and what goes public
# with it; Publish approves it (DataQuality::Review.publish), and, if
# ticked, the facts added by hand with it.
class Admin::RecordPublishController < Admin::BaseController
  before_action :load_record

  def show
    @plan = DataQuality::Review.publish_plan(type: @type, id: @record.id)
  end

  def create
    result = DataQuality::Review.publish(type: @type, id: @record.id, by: actor, with_added: (Array(params[:added]) if params[:with_added] == "1"))
    if result.ok?
      flash[:notice] = "Published."
    else
      flash[:alert] = "Not published: #{result.errors.to_sentence}"
    end
    redirect_after admin_record_path(type: @type, id: @record.id, back: params[:back].presence)
  end

  private
    def load_record
      @type = params[:type]
      @record = @type.constantize.find(params[:id])
      # Already public, or taken off (Put back is for that): nothing to publish here.
      unless @record.pending?
        flash[:alert] = "#{@record.name} isn't waiting to be published."
        redirect_after admin_record_path(type: @type, id: @record.id)
      end
    end
end
