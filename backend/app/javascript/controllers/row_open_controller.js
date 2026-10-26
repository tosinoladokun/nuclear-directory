import { Controller } from "@hotwired/stimulus"

// A deal row opens (a button, aria-expanded) to show its details in place (#556).
export default class extends Controller {
  static targets = ["button", "panel"]

  toggle() {
    const open = this.buttonTarget.getAttribute("aria-expanded") !== "true"
    this.buttonTarget.setAttribute("aria-expanded", String(open))
    this.panelTarget.hidden = !open
    this.element.classList.toggle("nd-crow--open", open)
  }
}
