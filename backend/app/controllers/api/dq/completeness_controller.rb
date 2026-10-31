# The outcome's completeness count for Data Quality's morning check: how many
# published companies have a category, website, description and HQ, and
# what each other one lacks. Read only.
#
#   GET /api/dq/completeness      => { complete, total, missing: {…}, companies: [{ slug, name, missing }] }
#   GET /api/dq/completeness.csv  the worklist as CSV
class Api::Dq::CompletenessController < ActionController::API
  include Api::DqAgent

  def show
    report = Completeness.new
    if request.format.csv?
      send_data report.to_csv, type: "text/csv", filename: "completeness.csv"
    else
      render json: { complete: report.complete_count, total: report.total, missing: report.missing_counts,
                     companies: report.rows.reject(&:complete?).map(&:to_h) }
    end
  end
end
