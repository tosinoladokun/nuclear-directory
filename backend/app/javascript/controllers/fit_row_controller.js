import { Controller } from "@hotwired/stimulus"

// A row of pills that shows only the ones that fit on one line, the rest
// hidden (so they leave the tab order too): fewer suggestions rather than a
// second line or a sideways scroll (Tosin, 21 Oct: four on phones, three on the
// smallest if four don't fit). Without JavaScript the row's own CSS shows the
// first line and clips the rest.
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
    // Pill widths change when a font arrives: fit again then, and once the page has loaded.
    document.fonts?.ready.then(this.fit)
    document.fonts?.addEventListener("loadingdone", this.fit)
    window.addEventListener("load", this.fit)
  }

  disconnect() {
    this.observer?.disconnect()
    document.fonts?.removeEventListener("loadingdone", this.fit)
    window.removeEventListener("load", this.fit)
  }
}
