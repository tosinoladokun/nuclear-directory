# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
# The instant search filter (#696): runs in the browser against /search/index.json.
pin "search_index"

# Anonymous page views and page leaves (#66): loaded lazily by app/javascript/analytics.js.
pin "analytics"
# posthog-js 1.438.7 (dist/module.mjs, Apache-2.0, licence beside it) is served
# from vendor/javascript, so no third-party code network sees visitors (#56).
pin "posthog-js", to: "posthog-js.js", preload: false
