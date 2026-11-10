import { Controller } from "@hotwired/stimulus"
import { prepare, search } from "search_index"

// One index per page, shared by the header and home search boxes: { promise, at, failed } by URL. A page visit starts with a
// fresh state for a failed or ten-minute-old entry (the HTTP cache lifetime), so Turbo visits don't keep either.
const indexes = {}
const INDEX_LIFETIME = 10 * 60 * 1000

// Instant results under a search field (#41). Typing loads /search?q= into a
// Turbo Frame below the field; Enter still submits the form to the full
// results. Arrow keys move between results, Escape closes them, and a polite
// live region announces how many results there are.
//
// With an index URL (#696) the results are filtered in the browser from a compact index fetched on first focus, so
// there is no wait per keystroke. Until the index is there, or if it can't be fetched, typing loads /search as before.
export default class extends Controller {
  static targets = ["input", "results", "frame", "status"]
  static values = { url: String, indexUrl: String, allUrl: String, minimum: { type: Number, default: 2 }, delay: { type: Number, default: 150 }, shortPlaceholder: String, longPlaceholder: String, nameFull: { type: Number, default: 26 }, nameSmall: { type: Number, default: 31 } }

  // Below 380px the full placeholder doesn't fit at 16px (iOS zooms below
  // 16px), so a shorter one takes its place (one-line law, #365). Both come
  // from the page, never from the field: after a reconnect (a Turbo snapshot)
  // the field may already hold the short one.
  connect() {
    const entry = indexes[this.indexUrlValue]
    if (entry && (entry.failed || Date.now() - entry.at > INDEX_LIFETIME)) delete indexes[this.indexUrlValue]
    this.index = null
    this.fetching = false
    if (!this.shortPlaceholderValue || !this.longPlaceholderValue) return
    this.longPlaceholder = this.longPlaceholderValue
    this.narrow = window.matchMedia("(max-width: 379px)")
    this.fitPlaceholder = () => { this.inputTarget.placeholder = this.narrow.matches ? this.shortPlaceholderValue : this.longPlaceholder }
    this.narrow.addEventListener("change", this.fitPlaceholder)
    this.fitPlaceholder()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.narrow?.removeEventListener("change", this.fitPlaceholder)
  }

  search(event) {
    // Focus moved back to the field by this controller isn't a new search.
    if (event?.type === "focus" && this.movingFocus) return

    clearTimeout(this.timer)
    this.pending = false
    this.dismissed = false
    this.fetchIndex()
    if (this.index) return this.renderLocal()

    this.markStale()
    this.timer = setTimeout(() => this.load(), this.delayValue)
  }

  // The index loads on first focus or keystroke (never with the page, so no cost to its load).
  fetchIndex() {
    if (!this.indexUrlValue || this.index || this.fetching) return
    this.fetching = true
    if (!indexes[this.indexUrlValue]) {
      const entry = { at: Date.now(), failed: false }
      entry.promise = fetch(this.indexUrlValue, { headers: { Accept: "application/json" } })
        .then((response) => (response.ok ? response.json() : Promise.reject(new Error(response.status))))
        .then(prepare)
      entry.promise.catch(() => { entry.failed = true })
      indexes[this.indexUrlValue] = entry
    }
    // A failed index stays cached for this page (the entry is shared), so an unavailable index is tried once per page.
    indexes[this.indexUrlValue].promise.then((index) => {
      this.index = index
      // Escape (or clearing the field) while it loaded keeps the results closed until the next search.
      if (!this.dismissed && this.inputTarget.value.trim().length >= this.minimumValue && this.inputTarget === document.activeElement) this.renderLocal()
    }).catch(() => {})
  }

  // A /search response that arrives after the local results took over must not replace them (Turbo can't cancel the request).
  beforeRender(event) {
    if (!this.index) return
    // Let the no-op render complete (no preventDefault: that would pause the frame's load, leaving it busy).
    event.detail.render = () => {}
  }

  renderLocal() {
    clearTimeout(this.timer)
    this.pending = false
    const text = this.inputTarget.value.trim()
    if (text.length < this.minimumValue) return this.close()

    const found = search(this.index, text)
    const total = found.topics.length + found.companies.length + found.plants.length
    this.frameTarget.replaceChildren(this.panel(text, found, total))
    this.statusTarget.textContent = total === 0 ? "No results" : `${found.fuzzy ? "No exact match. " : ""}${total} ${found.fuzzy ? (total === 1 ? "close name" : "close names") : (total === 1 ? "result" : "results")}, use the down arrow to browse`
    this.markFresh()
    this.open()
  }

  // The same markup the server's /search returns, so one stylesheet serves both.
  panel(text, found, total) {
    const make = (tag, className, content) => {
      const element = document.createElement(tag)
      if (className) element.className = className
      if (content !== undefined) element.textContent = content
      return element
    }
    // One line, as every list row (DirectoryHelper#line_name): the full name, then 13px, then the short name, ellipsis last.
    const nameElement = (name, shortName) => {
      let text = name, small = name.length > this.nameFullValue
      if (name.length > this.nameSmallValue && shortName && shortName.length <= this.nameSmallValue) text = shortName
      const element = make("b", "type-body-strong", text)
      element.title = name
      if (small) element.dataset.fit = "small"
      return element
    }
    const panel = make("div", "nd-instant")
    panel.dataset.instantSearchCount = total
    if (found.fuzzy) {
      panel.dataset.instantSearchFuzzy = "true"
      panel.append(make("p", "nd-instant__note type-small", `No exact match for “${text}”. Showing close names.`))
    }
    const group = (label, id, items, path) => {
      if (items.length === 0) return
      const heading = make("div", "nd-label nd-instant__group", label)
      heading.id = `${this.frameTarget.id}-${id}`
      const list = make("ul", "nd-instant__list")
      list.setAttribute("aria-labelledby", heading.id)
      items.forEach((item) => {
        const row = make("li")
        const link = make("a", "nd-instant__row")
        link.href = `${path}/${encodeURIComponent(item.s)}`
        const square = make("span", `nd-catsq${item.b ? ` ${item.b}` : ""}`)
        square.setAttribute("aria-hidden", "true")
        square.innerHTML = this.index.icons[item.i] || ""
        const label = make("span", "nd-instant__text")
        label.append(nameElement(item.n, item.sn))
        if (item.m) {
          const meta = make("span", "type-small", item.m)
          meta.title = item.m
          label.append(meta)
        }
        // The visible name may be the short one: the link's accessible name keeps the full name.
        link.setAttribute("aria-label", item.m ? `${item.n}, ${item.m}` : item.n)
        link.append(square, label)
        row.append(link)
        list.append(row)
      })
      panel.append(heading, list)
    }
    if (found.topics.length) {
      const heading = make("div", "nd-label nd-instant__group", "Topics")
      heading.id = `${this.frameTarget.id}-topics`
      const list = make("ul", "nd-instant__list")
      list.setAttribute("aria-labelledby", heading.id)
      found.topics.forEach((tag) => {
        const row = make("li")
        const link = make("a", "nd-instant__row")
        link.href = `/companies?tag=${encodeURIComponent(tag.s)}`
        const square = make("span", `nd-catsq${tag.b ? ` ${tag.b}` : ""}`)
        square.setAttribute("aria-hidden", "true")
        square.innerHTML = this.index.icons[tag.i] || ""
        const label = make("span", "nd-instant__text")
        label.append(nameElement(tag.n))
        if (tag.c) label.append(make("span", "type-small", `${tag.c} ${tag.c === 1 ? "company" : "companies"}`))
        link.append(square, label)
        row.append(link)
        list.append(row)
      })
      panel.append(heading, list)
    }
    group("Companies", "companies", found.companies, "/companies")
    group("Plants and sites", "plants", found.plants, "/plants")
    if (total === 0) {
      // The same words and the same one link as the server's fallback panel and the footer (#700).
      const empty = make("p", "nd-instant__empty type-body", `No results for “${text}”. `)
      const report = make("a", "nd-link", "Add a company")
      report.href = `/corrections/new?${new URLSearchParams({ subject: "A missing company", page: `/companies?q=${encodeURIComponent(text)}` })}`
      report.rel = "nofollow"
      empty.append(report)
      panel.append(empty)
    } else {
      const all = make("a", "nd-instant__all type-ui")
      const url = new URL(this.allUrlValue || "/companies", window.location.origin)
      url.searchParams.set("q", text)
      all.href = url.pathname + url.search
      all.append(make("span", "", `All results for “${text}”`), make("kbd", "type-data-sm", "Enter"))
      panel.append(all)
    }
    return panel
  }

  load() {
    const query = this.inputTarget.value.trim()
    if (query.length < this.minimumValue) return this.close()

    this.pending = true
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)
    this.frameTarget.src = url.toString()
  }

  // A load that finishes after the results were closed stays closed.
  loaded() {
    if (!this.pending) return
    // A response for an older query: the newer one is on its way, or the
    // field was cleared.
    const requested = new URL(this.frameTarget.src, window.location.origin).searchParams.get("q")
    if (requested !== this.inputTarget.value.trim()) return
    this.pending = false

    this.markFresh()
    const panel = this.frameTarget.querySelector("[data-instant-search-count]")
    if (!panel) return this.close()

    const count = Number(panel.dataset.instantSearchCount)
    const close = panel.dataset.instantSearchFuzzy === "true"
    const results = `${count} ${close ? (count === 1 ? "close name" : "close names") : (count === 1 ? "result" : "results")}`
    // Close names are approximate: say so, since ArrowDown skips the note in the panel.
    this.statusTarget.textContent = count === 0 ? "No results" : `${close ? "No exact match. " : ""}${results}, use the down arrow to browse`
    this.open()
  }

  // Keys pressed in the field.
  keydown(event) {
    if (event.key === "ArrowDown" && this.isOpen) {
      event.preventDefault()
      this.links[0]?.focus()
    } else if (event.key === "Escape" && this.isOpen) {
      // A search field clears itself on Escape; here it only closes the results.
      event.preventDefault()
      this.close()
    }
  }

  // Keys pressed while a result has focus.
  navigate(event) {
    const links = this.links
    const index = links.indexOf(document.activeElement)
    if (event.key === "ArrowDown") {
      event.preventDefault()
      links[Math.min(index + 1, links.length - 1)]?.focus()
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      index <= 0 ? this.focusInput() : links[index - 1].focus()
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      this.focusInput()
    }
  }

  // A click anywhere outside the search box closes the results.
  outside(event) {
    if (this.element.contains(event.target)) return
    // Focus left on a hidden result would be lost; a clicked control keeps it.
    if (this.resultsTarget.contains(document.activeElement)) this.focusInput()
    this.close()
  }

  open() {
    this.resultsTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
  }

  // A failed request closes the old results rather than leaving them up.
  failed(event) {
    if (event?.type === "turbo:frame-missing") event.preventDefault()
    // A late failure of the fallback request must not dismiss the local results.
    if (this.index) return
    this.pending = false
    this.close()
  }

  // Results for the previous text stay in view, dimmed and out of reach,
  // until the new ones arrive, so the list doesn't flicker as you type.
  markStale() {
    if (!this.isOpen) return
    this.resultsTarget.setAttribute("aria-busy", "true")
    this.resultsTarget.inert = true
  }

  markFresh() {
    this.resultsTarget.removeAttribute("aria-busy")
    this.resultsTarget.inert = false
  }

  close() {
    clearTimeout(this.timer)
    this.dismissed = true
    this.pending = false
    this.markFresh()
    this.resultsTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.statusTarget.textContent = ""
  }

  focusInput() {
    this.movingFocus = true
    this.inputTarget.focus()
    this.movingFocus = false
  }

  get isOpen() {
    return !this.resultsTarget.hidden
  }

  get links() {
    return Array.from(this.frameTarget.querySelectorAll("a"))
  }
}
