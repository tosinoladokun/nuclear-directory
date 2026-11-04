import { Controller } from "@hotwired/stimulus"

// Browsers without the Popover API don't know :popover-open (matches() would
// throw); there the form simply stays inline.
const popovers = typeof HTMLElement !== "undefined" && "popover" in HTMLElement.prototype

// The phone filter sheet (#90). Without JavaScript the sheet is a native
// popover that the "Filters (N)" button opens and closes on its own
// (popovertarget), so filtering never depends on this file. With it, the
// button opens the same contents in a modal <dialog> instead, so the page
// behind is inert and focus stays in the sheet, and the submit button
// counts what the choice would show ("Show 12 results"), with a polite
// status line saying the same. The sheet closes if the screen grows past
// phone width.
export default class extends Controller {
  static targets = ["sheet", "dialog", "form", "submit", "status"]
  static values = { countUrl: String }

  connect() {
    this.label = this.submitTarget.textContent
    // With JavaScript the inline filters apply as they change, so their Apply button is hidden (CSS, data-live); in the
    // phone sheet the button stays: it says how many results the choice shows.
    this.formTarget.dataset.live = ""
    this.restoreFocus()
    this.phone = window.matchMedia("(max-width: 560px)")
    this.leftPhone = () => { if (!this.phone.matches && this.isOpen) this.close() }
    this.phone.addEventListener("change", this.leftPhone)
    window.addEventListener("resize", this.leftPhone)

    // Tapped open before this connected: move it to the modal dialog.
    if (this.popoverOpen) {
      this.sheetTarget.hidePopover()
      this.openModal()
    }
  }

  disconnect() {
    clearTimeout(this.submitTimer)
    this.phone?.removeEventListener("change", this.leftPhone)
    window.removeEventListener("resize", this.leftPhone)
  }

  // The Filters button: a modal dialog instead of the popover.
  open(event) {
    event.preventDefault()
    this.openModal()
  }

  openModal() {
    this.dialogTarget.append(...this.sheetTarget.children)
    this.dialogTarget.showModal()
    this.count()
  }

  // Close filters, Escape (the dialog's cancel), the screen growing, or Turbo
  // about to cache the page (so Back never restores an open, non-modal copy).
  close(event) {
    event?.preventDefault()
    if (this.dialogTarget.open) this.dialogTarget.close()
    if (this.popoverOpen) this.sheetTarget.hidePopover()
    this.closed()
  }

  // The native popover opened or closed (the no-JavaScript path, or a tap
  // before this controller connected).
  toggled(event) {
    if (event.newState === "open") this.count()
    else if (!this.dialogTarget.open) this.closed() // not when it just moved to the modal
  }

  // The contents go back to their inline home. Also bound to the dialog's
  // close event, which some browsers deliver late; safe to run twice.
  closed() {
    // Choices made in the sheet and never applied go back to what the results show, so a rotation to the inline layout
    // can't leave a filter on screen that the list doesn't reflect.
    this.formTarget.reset()
    if (this.dialogTarget.children.length) this.sheetTarget.append(...this.dialogTarget.children)
    this.request = null
    this.show(this.label, "")
  }

  // A filter changed: in the sheet, count what it would show; inline, apply it.
  // The submit waits a moment so arrowing through a closed select doesn't navigate on every option, and the focused
  // control is remembered so the page that replaces this one can put focus back on it.
  changed(event) {
    if (this.isOpen) return this.count()
    clearTimeout(this.submitTimer)
    this.submitTimer = setTimeout(() => {
      const name = event?.target?.name
      if (name) sessionStorage.setItem("nd-filter-focus", name)
      this.formTarget.requestSubmit()
    }, 500)
  }

  restoreFocus() {
    const name = sessionStorage.getItem("nd-filter-focus")
    if (!name) return
    sessionStorage.removeItem("nd-filter-focus")
    const control = [...this.formTarget.elements].find((el) => el.name === name)
    if (control && control.getClientRects().length) control.focus({ preventScroll: true })
  }

  // Ask how many results the current choices give, and say so.
  async count() {
    if (!this.isOpen) return

    const request = (this.request = Symbol())
    // Until the new count arrives, the button mustn't promise the old one.
    this.show(this.label, "")
    const params = new URLSearchParams(new FormData(this.formTarget))
    let count = null
    try {
      const response = await fetch(`${this.countUrlValue}?${params}`, { headers: { Accept: "application/json" } })
      if (response.ok) count = (await response.json()).count
    } catch {
      count = null
    }
    if (request !== this.request) return // a newer choice is already being counted

    if (Number.isInteger(count)) {
      const words = `${count} ${count === 1 ? "result" : "results"}`
      this.show(`Show ${words}`, words)
    } else {
      this.show(this.label, "")
    }
  }

  show(label, status) {
    this.submitTarget.textContent = label
    this.statusTarget.textContent = status
  }

  get isOpen() {
    return this.dialogTarget.open || this.popoverOpen
  }

  get popoverOpen() {
    return popovers && this.sheetTarget.matches(":popover-open")
  }
}
