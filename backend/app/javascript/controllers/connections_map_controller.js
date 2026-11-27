import { Controller } from "@hotwired/stimulus"

// The connections map (#363, #561, #682). The server draws it as straight lines with each group's heading above its rows;
// once the fonts are in, this fits each name to its slot, then crops the drawing to what it draws, so the record and its
// branches sit centred under the heading as one unit (#995). Nothing is operated: no details card, no hover (the names
// link to the partners' pages).
//
// Names: shrink 0.5px at a time to the floor (13px), and every name in a column takes the smallest size any of them
// needed, so no name looks different from its neighbours (#995). Then, name by name, the short name, then an ellipsis
// (the full name stays in <title>).
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
      this.fitDrawing(svg)
      this.done.add(svg)
      svg.dataset.laidOut = "true"
    })
  }

  fitNames(svg) {
    const names = [ ...svg.querySelectorAll(".nd-map__name") ]
    names.forEach((text) => this.shrink(text, Number(text.dataset.font)))
    // One size per column: the smallest its names needed (the record's own name stands alone).
    ;[ "left", "right" ].forEach((side) => {
      const column = names.filter((text) => text.dataset.side === side)
      if (column.length === 0) return
      const size = Math.min(...column.map((text) => parseFloat(text.style.fontSize)))
      column.forEach((text) => { text.style.fontSize = `${size}px` })
    })
    names.forEach((text) => {
      if (this.fits(text)) return
      const words = text.firstChild
      if (text.dataset.short) {
        words.nodeValue = text.dataset.short
        if (!text.dataset.side) this.shrink(text, parseFloat(text.style.fontSize))
      }
      if (!this.fits(text)) {
        const full = words.nodeValue
        let cut = full.length
        while (cut > 1 && !this.fits(text)) words.nodeValue = `${full.slice(0, --cut).trimEnd()}…`
        text.dataset.truncate = ""
        console.warn(`connections map: "${full}" needs a short name`)
      }
    })
  }

  fits(text) {
    return text.getComputedTextLength() <= Number(text.dataset.slot)
  }

  // From size down 0.5px at a time to the floor, until the name fits its slot.
  shrink(text, size) {
    const floor = Number(text.dataset.floor)
    text.style.fontSize = `${size}px`
    while (!this.fits(text) && size > floor) {
      size = Math.max(floor, size - 0.5)
      text.style.fontSize = `${size}px`
    }
  }

  // The drawing is as wide and tall as what it draws (plus 4px), never scaled, so CSS can centre it (#995).
  fitDrawing(svg) {
    const boxes = [ ...svg.children ].filter((child) => child.tagName.toLowerCase() === "g").map((group) => group.getBBox())
      .filter((box) => box.width > 0 || box.height > 0)
    if (boxes.length === 0) return
    const left = Math.min(...boxes.map((box) => box.x)) - 4
    const top = Math.min(...boxes.map((box) => box.y)) - 4
    const width = Math.max(...boxes.map((box) => box.x + box.width)) + 4 - left
    const height = Math.max(...boxes.map((box) => box.y + box.height)) + 4 - top
    const round = (value) => Math.round(value * 10) / 10
    svg.setAttribute("viewBox", `${round(left)} ${round(top)} ${round(width)} ${round(height)}`)
    svg.setAttribute("width", Math.ceil(width))
    svg.setAttribute("height", Math.ceil(height))
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
