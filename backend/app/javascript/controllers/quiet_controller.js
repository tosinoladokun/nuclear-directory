import { Controller } from "@hotwired/stimulus"

// The quiet line's items that open a panel in place: the numbered sources and
// the citation (#556). Each button names its panel in data-panel. The panels
// are in the page open, so without JavaScript every link to them lands; once
// this runs they fold, and a link to #sources or #source-N unfolds them first.
export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.buttonTargets.forEach((button) => this.set(button, false))
    this.reveal = () => {
      const id = decodeURIComponent(window.location.hash.slice(1))
      const target = id && document.getElementById(id)
      if (!target) return

      const button = this.buttonTargets.find((item) => {
        const panel = document.getElementById(item.dataset.panel)
        return panel && (panel === target || panel.contains(target))
      })
      if (button && button.getAttribute("aria-expanded") !== "true") {
        this.set(button, true)
        target.scrollIntoView({ block: "start" })
      }
    }
    this.reveal()
    window.addEventListener("hashchange", this.reveal)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.reveal)
  }

  toggle(event) {
    const button = event.currentTarget
    this.set(button, button.getAttribute("aria-expanded") !== "true")
  }

  set(button, open) {
    button.setAttribute("aria-expanded", String(open))
    const panel = document.getElementById(button.dataset.panel)
    if (panel) panel.hidden = !open
  }
}
