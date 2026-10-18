import { Controller } from "@hotwired/stimulus"

// A related row's actions menu on a Record (#201, Design's spec on #166):
// opening one closes any other, and Esc closes it and returns focus to its
// button. A click outside closes it too.
export default class extends Controller {
  connect() {
    this.outside = (event) => { if (!this.element.contains(event.target)) this.element.open = false }
    document.addEventListener("click", this.outside)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
  }

  toggle() {
    if (!this.element.open) return

    document.querySelectorAll("details.nd-rowmenu[open]").forEach((menu) => {
      if (menu !== this.element) menu.open = false
    })
  }

  close(event) {
    if (!this.element.open) return

    event.preventDefault()
    this.element.open = false
    this.element.querySelector("summary").focus()
  }
}
