// Anonymous page views and page leaves through PostHog (#66). The layout adds the
// posthog-key / posthog-host meta tags only on public pages, for people (not
// bots), and only when analytics is configured; see TracksAnalytics.
//
// Cookieless: nothing is stored in the browser, nobody is identified, no
// session replay, no surveys, no click autocapture. Page views and page
// leaves (for bounce rate and time on page) are sent, plus dead clicks when
// they're on in the PostHog project (Tosin's choice), and every URL in them
// is cut back to its path, so query strings (which can hold an email or a
// search) never leave the page. Cookieless mode also strips the IP before
// PostHog stores anything (PostHog #48660), so there's no location from it;
// #205 adds a country looked up on our side. The
// library loads when the browser is idle, so it never slows a page down.
const meta = (name) => document.querySelector(`meta[name="${name}"]`)?.content

// "https://site/search?q=me@example.com#x" => "https://site/search"
export function withoutQuery(value) {
  if (typeof value !== "string" || !/^https?:\/\//.test(value)) return value
  try {
    const url = new URL(value)
    return url.origin + url.pathname
  } catch {
    return value.split(/[?#]/)[0]
  }
}

// Drops /design visits and strips query strings and fragments from every
// URL-valued property (current URL, referrer, initial URL, ...).
export function sanitize(event) {
  if (!event) return event
  const properties = event.properties || {}
  if (properties.$pathname?.startsWith("/design")) return null

  // Web vitals carry each metric's detail (nested events with their own URLs): the numbers stay, the objects go.
  for (const name of Object.keys(properties)) if (/^\$web_vitals_.*_event$/.test(name)) delete properties[name]
  for (const [name, value] of Object.entries(properties)) properties[name] = withoutQuery(value)
  if (event.$set) for (const [name, value] of Object.entries(event.$set)) event.$set[name] = withoutQuery(value)
  if (event.$set_once) for (const [name, value] of Object.entries(event.$set_once)) event.$set_once[name] = withoutQuery(value)
  if (event.event === "$pageview" && properties.$pathname === "/") Object.assign(properties, homeVariantProperties() || {})
  return event
}

// Outbound clicks (#492): which kind of link, to which domain, from which page. The destination is its domain only
// (no path, no query string) and the page is its company or plant slug, so there is nothing personal in the event.
// The link says what it is with data-outbound ("source"); a company's own website link carries our UTM source.
export function outboundProperties(anchor, here = window.location) {
  let url
  try {
    url = new URL(anchor.href, here.href)
  } catch {
    return null
  }
  if (!/^https?:$/.test(url.protocol) || url.host === here.host) return null

  const kind = anchor.dataset?.outbound || (url.searchParams.get("utm_source") === "nuclear-directory" ? "company_website" : "other")
  const from = here.pathname.match(/^\/(companies|plants)\/([\w-]+)\/?$/)
  return {
    kind,
    target_domain: url.hostname.replace(/^www\./, ""),
    from_slug: from ? from[2] : null,
    from_type: from ? (from[1] === "companies" ? "company" : "plant") : "other"
  }
}

// The home page A/B test (#909): the page names its version in a meta tag, and every home event carries it as
// home_variant (with home_variant_forced when a preview link chose it, so the readout can leave it out):
// - home_viewed, once the home page has rendered (its first load or a Turbo visit), the readout's count of home visits:
//   a Turbo visit can send its $pageview before the new page's head is in, so the page view alone can't be trusted
//   to name the version. The $pageview of "/" carries it too when the tag is already there.
// - home_search_started: the first keystroke in the search box, once per home view.
// - home_category_click: a click on a category, a card title in A or a Browse row, with the category's slug and
//   where it was clicked.
// - home_chart_click (with the chart's name) and home_download_click: B's chart cards and its "Download the data" link.
export function homeVariantProperties(doc = document) {
  const tag = doc.querySelector('meta[name="home-variant"]')
  if (!tag?.content) return null
  return tag.dataset.forced === "true" ? { home_variant: tag.content, home_variant_forced: true } : { home_variant: tag.content }
}

export function categoryClickProperties(anchor, here = window.location) {
  let url
  try {
    url = new URL(anchor.href, here.href)
  } catch {
    return null
  }
  return { category: url.searchParams.get("category"), from: anchor.closest(".nd-browse") ? "browse" : "card" }
}

let ready = null

// Home events wait here until PostHog has loaded (it loads when the browser is idle), so a search or a click made
// before then still counts, after its page's home_viewed. Each keeps the version of the page it happened on.
const homeQueue = []
function sendHome(name, properties, options) {
  ready ? ready.capture(name, properties, options) : homeQueue.push([ name, properties, options ])
}

// Once per home view: the mark is on the body, so Turbo's copy of the page, restored by Back, carries it and isn't
// counted again (the layout counts a restored page as no new view either).
function once(mark) {
  if (document.body.dataset[mark]) return false
  document.body.dataset[mark] = "true"
  return true
}

export function trackHomeView() {
  const variant = homeVariantProperties()
  if (variant && once("homeViewed")) sendHome("home_viewed", variant)
}

function trackHome(event) {
  const variant = homeVariantProperties()
  if (!variant) return
  if (event.type === "input") {
    if (!event.target.matches?.(".nd-home input[type=search]") || !event.target.value.trim() || !once("homeSearched")) return
    trackHomeView()
    sendHome("home_search_started", variant)
    return
  }
  if (event.type === "auxclick" && event.button !== 1) return
  // B's chart cards and its download link.
  const chart = event.target.closest?.("a[data-home-chart]")
  if (chart) return ready.capture("home_chart_click", { chart: chart.dataset.homeChart, ...variant }, { send_instantly: true })
  if (event.target.closest?.("a[data-home-download]")) return ready.capture("home_download_click", variant, { send_instantly: true })
  const anchor = event.target.closest?.("a[data-home-click]")
  const properties = anchor && categoryClickProperties(anchor)
  if (!properties) return
  trackHomeView()
  sendHome("home_category_click", { ...properties, ...variant }, { send_instantly: true })
}

// Listens from the start, before PostHog loads.
export function installHomeTracking() {
  document.addEventListener("click", trackHome, true)
  document.addEventListener("auxclick", trackHome, true)
  document.addEventListener("input", trackHome, true)
  document.addEventListener("turbo:load", trackHomeView)
  trackHomeView()
}

// PostHog is ready: send what waited, in order, then send directly.
export function homeReady(posthog) {
  ready = posthog
  homeQueue.splice(0).forEach(([ name, properties, options ]) => posthog.capture(name, properties, options))
}

export const pendingHomeEvents = () => homeQueue.map(([ name, properties ]) => [ name, properties ])

function trackOutbound(event) {
  // auxclick also fires for the right button (the context menu): only the middle button opens the link.
  if (event.type === "auxclick" && event.button !== 1) return
  const anchor = event.target.closest?.("a[href]")
  const properties = anchor && outboundProperties(anchor)
  if (properties && ready) ready.capture("outbound_click", properties, { send_instantly: true })
}

function start(key, host) {
  import("posthog-js").then(({ default: posthog }) => {
    posthog.init(key, {
      api_host: host, // our /relay (#205): the page views get a country, and blockers don't drop them
      ui_host: "https://us.posthog.com",
      disable_compression: true, // plain JSON (beacons are base64 anyway), so the relay can add the country
      cookieless_mode: "always",
      persistence: "memory",
      person_profiles: "never",
      capture_pageview: "history_change", // counts Turbo navigations too
      capture_pageleave: true, // bounce rate and time on page; same sanitized properties
      disable_scroll_properties: true, // no scroll depth: page leaves carry time on page only
      capture_performance: { web_vitals: true, web_vitals_allowed_metrics: [ "LCP", "CLS", "INP" ], network_timing: false }, // exactly these three (loaded through our /relay), whatever the dashboard lists; no per-request timings, which carry URLs
      autocapture: false, // no clicks, form events or element text
      disable_session_recording: true,
      disable_surveys: true,
      before_send: sanitize,
    })
    homeReady(posthog)
  })
  document.addEventListener("click", trackOutbound, true)
  document.addEventListener("auxclick", trackOutbound, true) // a middle click opens a tab too
}

if (typeof document !== "undefined") {
  const key = meta("posthog-key")
  const host = meta("posthog-host")
  if (key && host && !window.posthogStarted) {
    window.posthogStarted = true
    installHomeTracking()
    const begin = () => start(key, host)
    "requestIdleCallback" in window ? requestIdleCallback(begin) : setTimeout(begin, 1)
  }
}
