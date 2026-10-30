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

let ready = null
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
    ready = posthog
  })
  document.addEventListener("click", trackOutbound, true)
  document.addEventListener("auxclick", trackOutbound, true) // a middle click opens a tab too
}

if (typeof document !== "undefined") {
  const key = meta("posthog-key")
  const host = meta("posthog-host")
  if (key && host && !window.posthogStarted) {
    window.posthogStarted = true
    const begin = () => start(key, host)
    "requestIdleCallback" in window ? requestIdleCallback(begin) : setTimeout(begin, 1)
  }
}
