# "Claim or update this listing" and "suggest a new company or plant" (#591):
# each proposed change becomes a normal claim with the visitor's source, so it
# goes through matching, the checker, Data Quality's pre-check and Tosin's
# Yes like any other. Nothing publishes here. The claimant's email stays on
# the report; a work email on the company's own domain is noted as a signal
# for Data Quality and Tosin, never shown publicly.
#
#   ListingSubmission.call(report) # => the claims made, or []
class ListingSubmission
  ORIGIN = "visitor".freeze

  def self.call(report) = new(report).call

  def initialize(report)
    @report = report
  end

  def call
    return [] unless %w[listing new_record].include?(@report.kind)

    source = DataQuality::Sources.find_or_create(url: @report.source_url)
    return [] unless source.ok?

    record = (@report.record_type.constantize.find_by(id: @report.record_id) if @report.kind == "listing")
    return [] if @report.kind == "listing" && record.nil?

    @report.update!(email_domain_match: domain_match?(record)) if @report.claimant_email
    claims = (@report.kind == "listing" ? updates(record, source.ref) : [ new_record(source.ref) ])
    @report.update!(candidate_ids: claims.map(&:id))
    DataQuality::RunJob.perform_later(source.ref.source_kind, only: %w[match verify])
    claims
  end

  private
    def kind = @report.record_type == "Facility" ? "facility" : "organization"

    # One claim per change, naming the record as matching finds it.
    def updates(record, source)
      named = { "name" => record.name }
      named.merge!(record.slice(:nrc_docket, :eia_plant_id).compact.transform_keys(&:to_s)) if record.is_a?(Facility)
      @report.change_rows.map do |row|
        claim(source, named.merge(row["field"].to_s => row["value"].to_s.strip), row)
      end
    end

    def new_record(source)
      payload = @report.change_rows.to_h { |row| [ row["field"].to_s, row["value"].to_s.strip ] }
      claim(source, payload, @report.change_rows.find { |row| row["quote"].present? } || {})
    end

    def claim(source, payload, row)
      Candidate.create!(source_id: source.id, kind:, status: "new", origin: ORIGIN, payload:,
        quote: row["quote"].to_s.strip.presence || payload.except("name").values.first.to_s.presence || payload["name"],
        notes: [ "From a visitor (correction ##{@report.id})", ("their work email is on the company's domain" if @report.email_domain_match) ].compact.join("; "))
    end

    # A signal only: the email's domain is the company's own.
    def domain_match?(record)
      domain = @report.claimant_email.to_s.split("@").last.to_s.downcase
      record.respond_to?(:domain) && record.domain.present? && (domain == record.domain || domain.end_with?(".#{record.domain}"))
    end
end
