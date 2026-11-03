# Instant search's index (#696, SearchIndex), fetched once when a search box
# is first focused. Built once per version and kept in Rails.cache; the ETag
# is its version, so a browser that has it gets 304. No session cookie, so
# shared caches may keep it.
class SearchIndexesController < ApplicationController
  def show
    request.session_options[:skip] = true
    version = SearchIndex.version
    expires_in 10.minutes, public: true
    return unless stale?(etag: version, public: true)

    json = Rails.cache.fetch([ "search_index", version ], expires_in: 1.day) { SearchIndex.new.as_json.to_json }
    render json:
  end
end
