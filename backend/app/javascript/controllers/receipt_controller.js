import { Controller } from "@hotwired/stimulus"

// A decision made in Today (#1008): its row is replaced by a one-line receipt, which takes the focus so the
// place on the page, the Undo after a No, and the keyboard's position all stay where Tosin was (Design).
export default class extends Controller {
  connect() {
    this.element.focus()
  }
}
