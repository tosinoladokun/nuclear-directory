import { Controller } from "@hotwired/stimulus"

// Put on a turbo-frame whose contents grow in place ("Show more"): swapping
// them briefly empties the page, which would otherwise scroll it to the top.
export default class extends Controller {
  connect() {
    this.save = () => { this.y = window.scrollY }
    this.restore = () => window.scrollTo(0, this.y)
    this.element.addEventListener("turbo:before-frame-render", this.save)
    this.element.addEventListener("turbo:frame-render", this.restore)
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-frame-render", this.save)
    this.element.removeEventListener("turbo:frame-render", this.restore)
  }
}
