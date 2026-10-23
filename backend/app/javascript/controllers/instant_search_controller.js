import { Controller } from "@hotwired/stimulus"

// Instant results under a search field (#41). Typing loads /search?q= into a
// Turbo Frame below the field; Enter still submits the form to the full
// results. Arrow keys move between results, Escape closes them, and a polite
// live region announces how many results there are.
export default class extends Controller {
  static targets = ["input", "results", "frame", "status"]
  static values = { url: String, minimum: { type: Number, default: 2 }, delay: { type: Number, default: 150 }, shortPlaceholder: String, longPlaceholder: String }

  // Below 380px the full placeholder doesn't fit at 16px (iOS zooms below
  // 16px), so a shorter one takes its place (one-line law, #365). Both come
  // from the page, never from the field: after a reconnect (a Turbo snapshot)
  // the field may already hold the short one.
  connect() {
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
    this.markStale()
    this.timer = setTimeout(() => this.load(), this.delayValue)
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
    this.statusTarget.textContent = count === 0 ? "No results" : `${count} ${count === 1 ? "result" : "results"}, use the down arrow to browse`
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
