# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
# Controllers are lazy-loaded (controllers/index.js), so they are not modulepreloaded on every page.
pin_all_from "app/javascript/controllers", under: "controllers", preload: false

# Anonymous page views and page leaves (#66): loaded lazily by app/javascript/analytics.js.
pin "analytics"
# posthog-js 1.438.7 (dist/module.mjs, Apache-2.0, licence beside it) is served
# from vendor/javascript, so no third-party code network sees visitors (#56).
pin "posthog-js", to: "posthog-js.js", preload: false
