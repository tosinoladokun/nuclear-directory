import { Controller } from "@hotwired/stimulus"

// Homepage B's plant map (#940): hovering or tapping a dot shows the plant's name and state in a small label just above
// it. Near the card's edges the label moves inward, and below the dot when there's no room above. A dot isn't a link:
// clicking it (with any button) shows its label and doesn't open the card's page.
//
// - Mouse: the label stays while the pointer crosses the gap onto it, so it can be read under magnification (WCAG
//   1.4.13); Escape hides it.
// - Touch: a tap near a dot shows its label; a second tap on that dot, or a tap anywhere else, hides it.
const GAP = 6
// How far from a dot a finger may land and still pick it (CSS px).
const REACH = 16
// How long the label waits for the pointer to cross from the dot to it (ms).
const LINGER = 300

export default class extends Controller {
  static targets = [ "svg", "label", "name", "state" ]

  connect() {
    // A page Turbo restored from its cache may hold a label left open.
    this.element.querySelectorAll(".nd-chartmap__dot.is-active").forEach((dot) => dot.classList.remove("is-active"))
    this.labelTarget.hidden = true
    delete this.element.dataset.labelOpen
    delete this.element.dataset.mapTap

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

  over(event) {
    if (event.pointerType !== "mouse") return
    clearTimeout(this.leaving)
    if (this.isDot(event.target)) this.show(event.target)
  }

  // Leaving the dot or the label: hide unless the pointer reaches one of them in time.
  out(event) {
    if (event.pointerType !== "mouse" || !this.active) return
    if (event.target === this.active || this.labelTarget.contains(event.target)) {
      clearTimeout(this.leaving)
      this.leaving = setTimeout(() => this.hide(), LINGER)
    }
  }

  // A press begins. A finger is wider than a dot (6px on a phone), so a touch takes the nearest dot within reach.
  // data-map-tap tells the analytics this press is the map's, not a click on the card.
  down(event) {
    this.touch = event.pointerType !== "mouse"
    this.tapped = this.isDot(event.target) ? event.target : this.touch ? this.nearest(event) : null
    this.wasActive = this.active
    if (this.tapped || this.active) this.element.dataset.mapTap = ""
    else delete this.element.dataset.mapTap
  }

  click(event) {
    const mapTap = "mapTap" in this.element.dataset
    const dot = this.isDot(event.target) ? event.target : this.tapped
    const again = this.touch && dot && dot === this.wasActive
    delete this.element.dataset.mapTap
    this.tapped = this.wasActive = null
    if (dot || mapTap || this.active) event.preventDefault()
    // A middle click only stays put: it never opens the card's page in a new tab.
    if (event.type === "auxclick") return
    if (again) this.hide()
    else if (dot) this.show(dot)
    else if (mapTap || this.active) this.hide()
  }

  nearest({ clientX, clientY }) {
    let best = null
    let bestDistance = REACH
    this.element.querySelectorAll(".nd-chartmap__dot").forEach((dot) => {
      const box = dot.getBoundingClientRect()
      const distance = Math.hypot(box.left + box.width / 2 - clientX, box.top + box.height / 2 - clientY)
      if (distance <= bestDistance) [ best, bestDistance ] = [ dot, distance ]
    })
    return best
  }

  show(dot) {
    clearTimeout(this.leaving)
    if (this.active && this.active !== dot) this.active.classList.remove("is-active")
    this.active = dot
    dot.classList.add("is-active")
    this.nameTarget.textContent = dot.dataset.name
    this.stateTarget.textContent = dot.dataset.state || ""
    this.labelTarget.hidden = false
    this.element.dataset.labelOpen = ""
    this.place(dot)
  }

  hide() {
    clearTimeout(this.leaving)
    if (!this.active) return
    this.active.classList.remove("is-active")
    this.active = null
    this.labelTarget.hidden = true
    delete this.element.dataset.labelOpen
  }

  // From the dot's place in the drawing (not its box, which grows as it animates). Run again when the map resizes.
  place(dot) {
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

  isDot(element) {
    return element.classList?.contains("nd-chartmap__dot")
  }
}
