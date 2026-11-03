import { Controller } from "@hotwired/stimulus"

// The connections map (#363, #561, #682). The server draws it as straight lines with each group's heading above its rows;
// once the fonts are in, this fits each name to its slot. Nothing is operated: no details card, no hover (the names link
// to the partners' pages).
//
// Names: shrink 0.5px at a time to the floor (13px), then the short name, then an ellipsis (the full name stays in
// <title>).
export default class extends Controller {
  static targets = [ "figure", "view", "svg" ]

  connect() {
    this.done = new WeakSet()
    // Measure only once the web fonts are in: a fallback font's widths would stick.
    this.fontsReady = false
    this.observer = new ResizeObserver(() => this.layOut())
    this.observer.observe(this.figureTarget)
    const fonts = document.fonts ? document.fonts.ready : Promise.resolve()
    fonts.then(() => {
      this.fontsReady = true
      this.layOut()
    })
  }

  disconnect() {
    this.observer.disconnect()
  }

  // Each drawing once, when it's first on screen (a hidden one can't be measured).
  layOut() {
    if (!this.fontsReady) return
    this.svgTargets.forEach((svg) => {
      if (this.done.has(svg) || svg.getClientRects().length === 0) return
      this.fitNames(svg)
      this.done.add(svg)
      svg.dataset.laidOut = "true"
    })
  }

  fitNames(svg) {
    svg.querySelectorAll(".nd-map__name").forEach((text) => {
      const slot = Number(text.dataset.slot)
      const floor = Number(text.dataset.floor)
      const words = text.firstChild
      const fits = () => text.getComputedTextLength() <= slot
      const shrink = () => {
        let size = Number(text.dataset.font)
        text.style.fontSize = `${size}px`
        while (!fits() && size > floor) {
          size = Math.max(floor, size - 0.5)
          text.style.fontSize = `${size}px`
        }
      }
      shrink()
      if (!fits() && text.dataset.short) {
        words.nodeValue = text.dataset.short
        shrink()
      }
      if (!fits()) {
        const full = words.nodeValue
        let cut = full.length
        while (cut > 1 && !fits()) words.nodeValue = `${full.slice(0, --cut).trimEnd()}…`
        text.dataset.truncate = ""
        console.warn(`connections map: "${full}" needs a short name`)
      }
    })
  }

  // Folded plants open in place; "Back to all connections" folds them again.
  open() {
    this.swap("opened")
    this.element.querySelector(".nd-map__back")?.focus()
  }

  openKey(event) {
    if (event.key !== "Enter" && event.key !== " ") return
    event.preventDefault()
    this.open()
  }

  fold() {
    this.swap("folded")
    this.element.querySelector(".nd-map__view[data-view=folded] .nd-map__node--fold")?.focus()
  }

  swap(name) {
    this.viewTargets.forEach((view) => { view.hidden = view.dataset.view !== name })
    this.layOut()
  }
}
