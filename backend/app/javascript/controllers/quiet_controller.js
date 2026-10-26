import { Controller } from "@hotwired/stimulus"

// The quiet line's items that open a panel in place: the numbered sources and
// the citation (#556). Each button names its panel in data-panel.
export default class extends Controller {
  static targets = ["button"]

  toggle(event) {
    const button = event.currentTarget
    const open = button.getAttribute("aria-expanded") !== "true"
    button.setAttribute("aria-expanded", String(open))
    const panel = document.getElementById(button.dataset.panel)
    if (panel) panel.hidden = !open
  }

  // Opening a source from a mark or a link to #source-N shows the list first.
  show(id) {
    const button = this.buttonTargets.find((item) => item.dataset.panel === id)
    if (button && button.getAttribute("aria-expanded") !== "true") button.click()
  }
}
