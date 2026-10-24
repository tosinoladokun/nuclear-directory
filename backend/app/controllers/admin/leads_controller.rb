# Leads (#484): names that aren't facts yet, most-seen first, for Data
# Quality to work. Research starts Enrich when the lead is a company we have;
# otherwise it marks the lead as being researched. Already covered links the
# record that has it; Ignore needs a reason. Nothing here publishes: a lead
# becomes facts only as pending claims through the usual path.
class Admin::LeadsController < Admin::BaseController
  # The status filter (Design, on #543): its label and the statuses it shows.
  TABS = { "all" => [ "All", Lead::STATUSES ], "new" => [ "To do", %w[new] ], "researching" => [ "Researching", %w[researching] ],
    "added" => [ "Covered", %w[added] ], "ignored" => [ "Ignored", %w[ignored] ] }.freeze
  STATUS_LABELS = { "new" => "To do", "researching" => "Researching", "added" => "Covered", "ignored" => "Ignored" }.freeze
  # Sortable columns: Date is the last time a lead came up.
  SORTS = { "date" => :last_seen_on, "seen" => :seen_count }.freeze
  PAGE = 50

  def index
    LeadSync.run if params[:page].blank?
    @tab = params[:tab].presence_in(TABS.keys) || "new"
    @sort = params[:sort].presence_in(SORTS.keys) || "date"
    @dir = params[:dir] == "asc" ? "asc" : "desc"
    @page = [ params[:page].to_i, 1 ].max
    @leads = Lead.where(status: TABS.fetch(@tab).last).order(SORTS.fetch(@sort) => @dir, id: :asc)
      .offset((@page - 1) * PAGE).limit(PAGE + 1).to_a
    @more = @leads.size > PAGE
    @leads = @leads.first(PAGE)
    counts = Lead.group(:status).count
    @counts = TABS.transform_values { |(_, statuses)| statuses.sum { |status| counts[status].to_i } }
  end

  # A pasted list (one name per line, "Name: note" for a note), Data Quality's.
  def create
    # Data Quality's Leads.md table, row by row, its text kept (#484).
    if LeadImport.table?(params[:names])
      count = LeadImport.import!(params[:names], by: actor)
      return redirect_to(admin_leads_path, notice: "Imported #{helpers.pluralize(count, 'lead')} from the table.")
    end

    kind = params[:kind].presence_in(Lead::KINDS) || "other"
    added = params[:names].to_s.lines.map(&:strip).reject(&:empty?).first(500).filter_map do |line|
      name, note = line.split(/\s*[:—–]\s+/, 2)
      lead = Lead.sighted!(name:, kind:, key: "list:#{Lead.normalize(name)}", label: "Added by hand") or next
      lead.update!(note:) if note.present? && lead.note.blank?
      lead
    end
    redirect_to admin_leads_path, notice: "Added #{helpers.pluralize(added.size, 'lead')}."
  end

  def refresh
    LeadSync.run
    redirect_to admin_leads_path(params.permit(:tab, :sort, :dir).to_h.compact_blank), notice: "Leads brought up to date."
  end

  def research
    lead = Lead.find(params[:id])
    company = lead.record if lead.record_type == "Organization"
    company ||= Organization.where(verification_status: %w[verified pending]).find_by("LOWER(name) = ?", lead.name.downcase) if lead.kind == "company"
    lead.decide!("researching", by: actor, record: company)
    if company
      # As Enrich's own button: refused for an address that can't be read.
      refusal = Admin::RecordEnrichController.request!(company)
      return redirect_to(admin_record_enrich_path(type: "Organization", id: company.id),
        refusal ? { alert: refusal } : { notice: "Reading #{company.name}'s pages." })
    end
    back "Marked as being researched. What Data Quality finds comes back as claims to approve."
  end

  def covered
    lead = Lead.find(params[:id])
    name = params[:record].to_s.strip
    record = if name.present?
      # Only a record still in the directory (published or waiting), never a removed one.
      live = %w[verified pending]
      (ref = Directory::Lookup.organization(name:)) && Organization.where(verification_status: live).find_by(id: ref.id) ||
        Facility.where(verification_status: live).find_by(id: Directory::Lookup.facility(name:)&.id)
    end
    return back("No company or plant is called “#{params[:record]}”. Check the spelling, or Research it instead.", alert: true) unless record

    lead.decide!("added", by: actor, record:)
    back "Linked to #{record.name}."
  end

  def ignore
    lead = Lead.find(params[:id])
    return back("Say why it's ignored.", alert: true) if params[:reason].blank?

    lead.decide!("ignored", by: actor, reason: params[:reason].to_s.squish.first(500))
    back "Ignored."
  end

  def reopen
    Lead.find(params[:id]).decide!("new", by: actor)
    back "Back in New."
  end

  private
    def back(message, alert: false)
      redirect_to admin_leads_path(params.permit(:tab, :sort, :dir).to_h.compact_blank), (alert ? :alert : :notice) => message
    end
end
