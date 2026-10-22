import { Controller } from "@hotwired/stimulus"

// A fold that starts open on wide screens and closed on phones.
export default class extends Controller {
  connect() {
    if (window.matchMedia("(max-width: 560px)").matches) this.element.open = false
  }
}
