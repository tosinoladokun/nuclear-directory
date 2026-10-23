# Sources (#201 part 2b, Design's spec on #166): one row per source,
# grouped (official records by crawler, hand research by publisher), then
# every document in one, and a search across all of them. The pipeline's
# health (needs attention, last run per stage, model spend, visitors) is on
# Overview.
class Admin::SourcesController < Admin::BaseController
  STATUS_CHIPS = %w[pending ok blocked needs_human].freeze

  # ?by=category: Sources by category (#166), which categories have a live source.
  def index
    if params[:by] == "category"
      @coverage = SourceCoverage.new
      return render :by_category
    end

    @official = SourceCatalog.official
    @research = SourceCatalog.research
    @rows = DataQuality::Status.by_kind
    @runs_by_kind = @rows.index_by(&:source_kind)
  end

  def show
    @entry = SourceCatalog.entry(params[:key]) or raise ActiveRecord::RecordNotFound
    all = SourceCatalog.documents(@entry.key)
    @counts = STATUS_CHIPS.index_with { |status| all.count { |document| document.status == status } }
    @status = params[:status].presence_in(STATUS_CHIPS)
    @documents = @status ? all.select { |document| document.status == @status } : all
    @runs = SourceCatalog.runs(@entry.kind) if @entry.kind
  end

  def search
    @query = params[:q].to_s.strip
    @documents = @query.present? ? SourceCatalog.search(@query) : []
  end
end
