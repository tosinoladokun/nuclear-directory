import { Controller } from "@hotwired/stimulus"

// Opens the folded section the address names (#waste-and-decommissioning),
// so a link to one category lands on it open (Sources by category, #166).
export default class extends Controller {
  connect() {
    this.open = () => {
      const id = decodeURIComponent(window.location.hash.slice(1))
      const target = id && this.element.querySelector(`details[id="${CSS.escape(id)}"]`)
      if (!target) return

      target.open = true
      target.scrollIntoView({ block: "start" })
    }
    this.open()
    window.addEventListener("hashchange", this.open)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.open)
  }
}
