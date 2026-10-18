import { Controller } from "@hotwired/stimulus"

// The pill row scrolls sideways on phones; bring the current pill into view
// so it isn't hidden past the edge. A stopgap until the pills wrap (#334).
export default class extends Controller {
  connect() {
    this.element.querySelector("[aria-current='page']")?.scrollIntoView({ inline: "center", block: "nearest" })
  }
}
