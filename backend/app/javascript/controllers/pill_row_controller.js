import { Controller } from "@hotwired/stimulus"

// The pill and chip rows scroll sideways on phones; bring the current one into
// view so it isn't hidden past the edge, scrolling the row only (never the page).
// A stopgap for the pills until they wrap (#334); the chips (#558) keep it.
export default class extends Controller {
  connect() {
    const current = this.element.querySelector("[aria-current]")
    if (!current || this.element.scrollWidth <= this.element.clientWidth) return

    const row = this.element.getBoundingClientRect()
    const chip = current.getBoundingClientRect()
    this.element.scrollLeft += chip.left - row.left - (row.width - chip.width) / 2
  }
}
