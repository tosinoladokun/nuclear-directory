class ApplicationController < ActionController::Base
  include TracksAnalytics

  # Every browser gets the pages: a public directory turns no reader away,
  # and an older one only loses some styling. (Rails' allow_browser :modern
  # answered 406 to Safari before 17.2, on older iPhones and Macs.)

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
end
