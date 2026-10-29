# One page, one source (DQ's #667): a page stored under two addresses that
# differ only by a trailing slash ("https://www.converdyn.com" and
# "https://www.converdyn.com/") was two Source rows, so a company could cite
# its homepage twice. The seed now uses the form without the slash; this
# merges each such pair into that row. Evidence moves (a quote the kept row
# already has for the same fact is dropped as a duplicate), claims move, and
# the slash row goes. Nothing a person decided changes: only which row the
# same page's quotes hang on. Merging this PR is Tosin's approval.
class MergeSlashDuplicateSources < DeployData::Migration
  BY = "human:tosin"
  SNAPSHOT = %w[crawl_status status_reason http_status fetched_at content_sha256 content_text etag last_modified
    extracted_sha256 extracted_rows_sha256 final_url].freeze

  def up
    merged = 0
    Source.where("url LIKE '%/'").find_each do |extra|
      kept = Source.find_by(url: extra.url.chomp("/")) or next
      next if kept.id == extra.id

      moved, dropped = move_evidence(extra, kept)
      claims = Candidate.where(source_id: extra.id).update_all(source_id: kept.id, updated_at: Time.current)
      # The kept row takes what it lacks: a title, and the stored copy of the
      # page (so a claim's quote can still be checked against it). Its own
      # snapshot, when it has one, stays.
      taken = {}
      taken[:title] = extra.title if kept.title.blank? && extra.title.present?
      taken.merge!(extra.slice(*SNAPSHOT).symbolize_keys) if kept.content_sha256.blank? && extra.content_sha256.present?
      kept.update_columns(**taken, updated_at: Time.current) if taken.any?
      extra.destroy!
      merged += 1
      say "#{extra.url} -> #{kept.url}: #{moved} quotes moved, #{dropped} duplicates dropped, #{claims} claims moved"
    end
    say "Merged #{merged} sources into the same page without a trailing slash"
  end

  private
    def move_evidence(extra, kept)
      moved = dropped = 0
      Evidence.where(source_id: extra.id).find_each do |row|
        same = Evidence.find_by(source_id: kept.id, subject_type: row.subject_type, subject_id: row.subject_id, quote: row.quote)
        if same
          # The fields a quote backs (#398) gather on the row kept.
          same.update!(fields: [ *same.fields, *row.fields ]) if row.fields.present?
          row.destroy!
          dropped += 1
        else
          row.update!(source_id: kept.id)
          moved += 1
        end
      end
      [ moved, dropped ]
    end
end
