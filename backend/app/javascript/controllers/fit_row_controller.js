import { Controller } from "@hotwired/stimulus"

// A row of pills that shows only the ones that fit on one line, the rest
// hidden (so they leave the tab order too): fewer suggestions rather than a
// second line or a sideways scroll (Tosin, 21 Oct). If fewer than `minimum`
// of the picked ones fit, the `minimum` shortest of all of them (the picked
// and the spares) are shown instead, rather than dropping to fewer. Without
// JavaScript the row's own CSS shows the first line and clips the rest.
export default class extends Controller {
  static targets = ["item"]
  static values = { minimum: { type: Number, default: 0 } }

  connect() {
    this.fit = () => {
      const picked = this.itemTargets.filter((item) => !item.classList.contains("nd-sugg--spare"))
      this.show(picked)
      if (this.visible().length >= this.minimumValue) return

      this.itemTargets.forEach((item) => { item.hidden = false })
      const shortest = [...this.itemTargets].sort((a, b) => a.offsetWidth - b.offsetWidth).slice(0, this.minimumValue)
      this.show(this.itemTargets.filter((item) => shortest.includes(item)))
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

  visible() { return this.itemTargets.filter((item) => !item.hidden) }

  // Shows exactly these (in order), minus any that wrap onto a second line.
  show(items) {
    this.itemTargets.forEach((item) => { item.hidden = !items.includes(item) })
    const first = items[0]?.offsetTop
    items.forEach((item) => { if (item.offsetTop > first) item.hidden = true })
  }
}
