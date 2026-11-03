# One stamp for "the published data may have changed" (PM, 2 Nov: speed): the
# cache key for home cards and whole company and plant pages, so a page is
# built once per change instead of on every visit.
#
#   DataVersion.current # => "3f9a…"
#
# It reads each table a public page shows from (latest change and row count;
# evidence, which has no updated_at, by its rows and their subjects), plus the
# deploy and today's date (pages say "Accessed <date>" and read link dates
# against today). Kept in this process for TTL, and dropped at once when a
# fact changes here (Verifiable, through DirectorySnapshot.expire!); a change
# from another process (the crawler, a console) shows within TTL.
module DataVersion
  TTL = 1.minute
  TABLES = [ Organization, Facility, OrganizationAlias, FacilityAlias, OrganizationRole, OrganizationTechnology, Role, Technology,
             Relationship, FacilityRelationship, DealTerm, LicensingStage, NewsItem, NewsMention, Source ].freeze
  # The code behind the pages: a deploy draws every page again.
  REVISION = ENV["RENDER_GIT_COMMIT"].presence || Time.current.to_i.to_s

  @lock = Mutex.new
  @memo = nil

  def self.current
    @lock.synchronize do
      @memo = nil if @memo && @memo[:at] < TTL.ago
      (@memo ||= { at: Time.current, value: compute })[:value]
    end
  end

  def self.expire! = @lock.synchronize { @memo = nil }

  def self.compute
    stamps = TABLES.map { |model| model.pick(Arel.sql("MAX(updated_at)"), Arel.sql("COUNT(*)")).then { |at, count| "#{at&.utc&.iso8601(6)}/#{count}" } }
    stamps << Evidence.pick(Arel.sql("MAX(id)"), Arel.sql("COUNT(*)"), Arel.sql("SUM(subject_id)"), Arel.sql("SUM(hashtext(subject_type))")).join("/")
    stamps << VerificationEvent.maximum(:id).to_s
    Digest::SHA256.hexdigest([ REVISION, Date.current.iso8601, *stamps ].join("|")).first(20)
  end
end
