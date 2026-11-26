import { Controller } from "@hotwired/stimulus"

// Homepage B's plant map (#940, #949). Each dot is a link to its plant; plants on one spot share a dot, a link each.
// Hovering, tapping or focusing a dot shows a label just above it: the plant's name and state, itself a link to the
// plant, or for a shared dot a chooser with each plant's name a link. Near the card's edges the label moves inward, and
// below the dot when there's no room above.
//
// - Mouse: a click on a dot opens its plant; a click on a shared dot keeps its chooser open. The label stays while the
//   pointer crosses the gap onto it (WCAG 1.4.13); Escape hides it.
// - Touch: the first tap picks the nearest dot within reach and shows its label; a second tap on the dot or the label
//   opens the plant (on a shared dot, a tap on a name). A dot is 6px wide on a phone, so opening on the first tap would
//   often open the wrong plant.
// - Keyboard: the map is one tab stop. The arrow keys go from plant to plant, west to east, Home and End to the ends,
//   and Enter opens the plant. The focused dot gets a ring drawn in the SVG (outlines on SVG links aren't reliable in
//   Safari).
//
// data-map-tap marks a press the map keeps (a tap that shows or hides a label), so the analytics don't count it as a
// click on a plant.
const GAP = 6
// How far from a dot a finger may land and still pick it (CSS px).
const REACH = 16
// How long the label waits for the pointer to cross from the dot to it (ms).
const LINGER = 300

export default class extends Controller {
  static targets = [ "svg", "label", "ring" ]

  connect() {
    // A page Turbo restored from its cache may hold a label left open.
    this.element.querySelectorAll(".nd-chartmap__spot.is-active").forEach((spot) => spot.classList.remove("is-active"))
    this.labelTarget.hidden = true
    this.labelTarget.replaceChildren()
    this.ringTarget.setAttribute("visibility", "hidden")
    delete this.element.dataset.labelOpen
    delete this.element.dataset.mapTap
    // One tab stop: the first plant, or the one last focused.
    this.links.forEach((link, i) => link.setAttribute("tabindex", i ? "-1" : "0"))

    this.outside = (event) => { if (!this.element.contains(event.target)) this.hide() }
    this.escape = (event) => { if (event.key === "Escape") this.hide() }
    this.beforeCache = () => this.hide()
    document.addEventListener("click", this.outside, true)
    document.addEventListener("keydown", this.escape)
    document.addEventListener("turbo:before-cache", this.beforeCache)
    this.resized = new ResizeObserver(() => { if (this.active) this.place(this.active) })
    this.resized.observe(this.element)
  }

  disconnect() {
    clearTimeout(this.leaving)
    document.removeEventListener("click", this.outside, true)
    document.removeEventListener("keydown", this.escape)
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    this.resized.disconnect()
  }

  get links() {
    return [ ...this.element.querySelectorAll(".nd-chartmap__link") ]
  }

  over(event) {
    if (event.pointerType !== "mouse") return
    const spot = this.spotOf(event.target)
    if (spot || this.labelTarget.contains(event.target)) clearTimeout(this.leaving)
    if (spot && spot !== this.active) this.show(spot)
  }

  // Leaving the dot or the label: hide unless the pointer reaches one of them in time. A chooser opened by a click stays.
  out(event) {
    if (event.pointerType !== "mouse" || !this.active || this.pinned) return
    if (this.spotOf(event.target) === this.active || this.labelTarget.contains(event.target)) {
      clearTimeout(this.leaving)
      this.leaving = setTimeout(() => this.hide(), LINGER)
    }
  }

  // A press begins: decide what its click will do. A finger is wider than a dot, so a touch takes the nearest dot within
  // reach.
  down(event) {
    this.intent = this.spot = null
    delete this.element.dataset.mapTap
    if (event.button !== 0) return

    const touch = event.pointerType !== "mouse"
    const inLabel = this.labelTarget.contains(event.target)
    const spot = this.spotOf(event.target) || (touch && !inLabel ? this.nearest(event) : null)
    if (inLabel) this.intent = event.target.closest("a") ? null : "keep"
    else if (spot && !touch) this.intent = this.shared(spot) ? "pin" : null
    else if (spot) this.intent = spot !== this.active ? "show" : this.shared(spot) ? "keep" : "open"
    else if (this.active) this.intent = "hide"
    this.spot = spot
    if (this.intent) this.element.dataset.mapTap = ""
  }

  click(event) {
    const { intent, spot } = this
    this.intent = this.spot = null
    delete this.element.dataset.mapTap
    // A middle click, Enter on a focused dot, a click on a dot or a label's link: the link opens as usual.
    if (event.type === "auxclick" || !intent) return

    event.preventDefault()
    if (intent === "show" || intent === "pin") this.show(spot, { pinned: intent === "pin" })
    else if (intent === "hide") this.hide()
    else if (intent === "open") this.labelTarget.querySelector("a")?.click()
  }

  focus(event) {
    const link = event.target.closest?.(".nd-chartmap__link")
    if (!link) return
    this.links.forEach((other) => other.setAttribute("tabindex", other === link ? "0" : "-1"))
    const keyboard = link.matches(":focus-visible")
    if (this.active !== this.spotOf(link) || keyboard) this.show(this.spotOf(link), { current: keyboard ? link : null })
    if (keyboard) {
      const dot = link.querySelector("circle")
      this.ringTarget.setAttribute("cx", dot.getAttribute("cx"))
      this.ringTarget.setAttribute("cy", dot.getAttribute("cy"))
      this.ringTarget.setAttribute("visibility", "visible")
    }
  }

  blur(event) {
    this.ringTarget.setAttribute("visibility", "hidden")
    if (!this.element.contains(event.relatedTarget) && !this.pinned) this.hide()
  }

  key(event) {
    const link = event.target.closest?.(".nd-chartmap__link")
    if (!link) return
    const links = this.links
    const at = links.indexOf(link)
    const to = { ArrowRight: at + 1, ArrowDown: at + 1, ArrowLeft: at - 1, ArrowUp: at - 1, Home: 0, End: links.length - 1 }[event.key]
    if (to === undefined) return
    event.preventDefault()
    links[Math.min(Math.max(to, 0), links.length - 1)].focus()
  }

  nearest({ clientX, clientY }) {
    let best = null
    let bestDistance = REACH
    this.element.querySelectorAll(".nd-chartmap__spot").forEach((spot) => {
      const box = spot.querySelector("circle").getBoundingClientRect()
      const distance = Math.hypot(box.left + box.width / 2 - clientX, box.top + box.height / 2 - clientY)
      if (distance <= bestDistance) [ best, bestDistance ] = [ spot, distance ]
    })
    return best
  }

  // The label: one plant's name and state, all one link; or a chooser, a linked name per plant and the state once
  // under them. With a plant focused by keyboard, the other names are muted.
  show(spot, { pinned = false, current = null } = {}) {
    clearTimeout(this.leaving)
    if (this.active && this.active !== spot) this.active.classList.remove("is-active")
    this.active = spot
    this.pinned = pinned
    spot.classList.add("is-active")

    const links = [ ...spot.querySelectorAll(".nd-chartmap__link") ]
    const state = this.span("nd-chartmap__state type-small", spot.dataset.state || "")
    if (links.length === 1) {
      const plant = this.link(links[0], "nd-chartmap__plant")
      plant.append(this.span("nd-chartmap__name type-ui", links[0].dataset.name), state)
      this.labelTarget.replaceChildren(plant)
    } else {
      const names = links.map((link) => {
        const name = this.link(link, "nd-chartmap__name type-ui")
        name.textContent = link.dataset.name
        if (current && link !== current) name.classList.add("is-muted")
        return name
      })
      this.labelTarget.replaceChildren(...names, state)
    }
    this.labelTarget.hidden = false
    this.element.dataset.labelOpen = ""
    this.place(spot)
  }

  hide() {
    clearTimeout(this.leaving)
    this.pinned = false
    if (!this.active) return
    this.active.classList.remove("is-active")
    this.active = null
    this.labelTarget.hidden = true
    this.labelTarget.replaceChildren()
    delete this.element.dataset.labelOpen
  }

  // From the dot's place in the drawing (not its box, which grows as it animates). Run again when the map resizes.
  place(spot) {
    const dot = spot.querySelector("circle")
    const wrap = this.element.getBoundingClientRect()
    const svg = this.svgTarget.getBoundingClientRect()
    const scale = svg.width / this.svgTarget.viewBox.baseVal.width
    const x = svg.left - wrap.left + dot.cx.baseVal.value * scale
    const y = svg.top - wrap.top + dot.cy.baseVal.value * scale
    const radius = 9 * scale
    const { width, height } = this.labelTarget.getBoundingClientRect()
    const left = Math.min(Math.max(x - width / 2, 0), Math.max(wrap.width - width, 0))
    const above = y - radius - GAP - height
    this.labelTarget.style.left = `${left}px`
    this.labelTarget.style.top = `${above >= 0 ? above : y + radius + GAP}px`
  }

  // The label's links copy the dot's; they're for pointers only (the dots are the keyboard's), so out of the tab order.
  link(dotLink, className) {
    const link = document.createElement("a")
    link.className = className
    link.href = dotLink.getAttribute("href")
    link.tabIndex = -1
    link.dataset.homeRecord = "plant"
    return link
  }

  span(className, text) {
    const span = document.createElement("span")
    span.className = className
    span.textContent = text
    return span
  }

  spotOf(element) {
    return element?.closest?.(".nd-chartmap__spot") || null
  }

  shared(spot) {
    return spot.querySelectorAll(".nd-chartmap__link").length > 1
  }
}
