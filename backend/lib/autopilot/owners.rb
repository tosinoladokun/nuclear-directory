module Autopilot
  module Owners
    # Which session fixes each alert (PM, 20 Nov, #811 "alert -> fix"): shown in the email and the alerts endpoint, and
    # the Mac poller messages that session. A key not listed goes to PM.
    MAP = {
      "queue-stuck" => "Infra", "db-restarted" => "Infra", "data-deploy-failed" => "Infra", "indexnow-refused" => "Infra",
      "crawl-silent" => "Crawl", "sources-silent" => "Crawl", "finder-silent" => "Crawl", "search-limit" => "Crawl",
      "company-pages-failing" => "Crawl",
      "pending-without-role" => "DQ", "pending-without-website" => "DQ", "unchecked-claims" => "DQ", "stuck-leads" => "DQ", "finds-unconfirmed" => "DQ",
      "no-creates" => "DQ",
      "social-silent" => "Backend", "posts-unknown" => "Backend",
      "budget" => "PM"
    }.freeze

    def self.for(key) = MAP.fetch(key.to_s, "PM")
  end
end
