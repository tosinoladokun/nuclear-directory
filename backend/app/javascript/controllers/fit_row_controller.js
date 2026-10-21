import { Controller } from "@hotwired/stimulus"

// A row of pills that shows only the ones that fit on one line, the rest
// hidden (so they leave the tab order too): fewer suggestions rather than a
// second line or a sideways scroll (Tosin, 21 Oct). Without JavaScript the
// row's own CSS shows the first line and clips the rest.
export default class extends Controller {
  static targets = ["item"]

  connect() {
    this.fit = () => {
      this.itemTargets.forEach((item) => { item.hidden = false })
      const first = this.itemTargets[0]?.offsetTop
      this.itemTargets.forEach((item) => { if (item.offsetTop > first) item.hidden = true })
    }
    this.observer = new ResizeObserver(this.fit)
    this.observer.observe(this.element)
    this.fit()
    document.fonts?.ready.then(this.fit)
  }

  disconnect() {
    this.observer?.disconnect()
  }
}
