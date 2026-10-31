# What's new (PM, 31 Oct): the Atom feed of newly approved facts, deals and
# news (Updates). Site's /updates page reads the same entries.
class UpdatesController < ApplicationController
  def index
    @entries = Updates.new.entries(limit: 50)
    expires_in 10.minutes, public: true
  end

  def feed
    @entries = Updates.new.entries(limit: 50)
    expires_in 1.hour, public: true
    render formats: :atom, content_type: "application/atom+xml"
  end
end
