# Add a record (#202): a company (with what it does) or a plant site, by
# hand, from a public source and its quote. The form previews with a GET
# (DataQuality::Review.add_record in a dry run, so the preview checks what
# creating would); Create record writes it. It starts unpublished: it's
# published from its Record page.
class Admin::NewRecordsController < Admin::BaseController
  FIELDS = %i[kind name website role facility_type url quote].freeze

  def new
    @kind = params[:kind].presence_in(%w[organization facility]) || "organization"
    return unless params[:preview]

    @added = add(dry_run: true)
  end

  def create
    @kind = params[:kind].presence_in(%w[organization facility]) || "organization"
    @added = add(dry_run: false)
    unless @added.ok?
      return render :new, status: :unprocessable_content
    end

    flash[:notice] = "Added #{params[:name].to_s.squish}. It isn't published yet."
    redirect_after admin_record_path(type: @added.ref.type, id: @added.ref.id, back: params[:back].presence)
  end

  private
    def add(dry_run:)
      DataQuality::Review.add_record(kind: @kind, name: params[:name], website: params[:website], role: params[:role],
        facility_type: params[:facility_type], url: params[:url], quote: params[:quote], by: actor, dry_run:)
    end
end
