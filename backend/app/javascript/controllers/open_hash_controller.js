import { Controller } from "@hotwired/stimulus"

// Opens the folded section the address names (#waste-decommissioning), so
// a link to one category lands on it open (Sources by category, #166). Only
// on the page's first load and on a later change of address: the "applied"
// value is kept in the page Turbo caches, so Back to it shows the sections
// as they were left, not reopened.
export default class extends Controller {
  static values = { applied: Boolean }

  connect() {
    this.open = () => {
      const id = decodeURIComponent(window.location.hash.slice(1))
      const target = id && this.element.querySelector(`details[id="${CSS.escape(id)}"]`)
      if (!target) return

      target.open = true
      target.scrollIntoView({ block: "start" })
    }
    if (!this.appliedValue) {
      this.open()
      this.appliedValue = true
    }
    window.addEventListener("hashchange", this.open)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.open)
  }
}
