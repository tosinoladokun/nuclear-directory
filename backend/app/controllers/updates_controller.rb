# What's new (PM, 31 Oct): the Atom feed of newly approved facts, deals and
# news (Updates). Site's /updates page reads the same entries. Built at most
# once an hour per host and sent without a session cookie, so polling readers
# and shared caches cost one build an hour (Infra).
class UpdatesController < ApplicationController
  CACHE_FOR = 1.hour

  def index
    @entries = Updates.new.entries(limit: 50)
    expires_in 10.minutes, public: true
  end

  def feed
    request.session_options[:skip] = true
    expires_in CACHE_FOR, public: true
    xml = Rails.cache.fetch([ "updates_feed", request.host ], expires_in: CACHE_FOR) do
      @entries = Updates.new.entries(limit: 50)
      render_to_string(formats: :atom)
    end
    render xml:, content_type: "application/atom+xml"
  end
end
