import { Controller } from "@hotwired/stimulus"

// Homepage B's plant map (#940): hovering, focusing or tapping a dot shows the plant's name and state in a small label
// just above it. Near the card's edges the label moves inward, and below the dot when there's no room above. A dot isn't
// a link: clicking it shows its label and doesn't open the card's page. On a phone, a tap near a dot shows its label, a tap
// elsewhere hides it, and a tap on the map while a label shows only hides it.
const GAP = 6
// How far from a dot a finger may land and still pick it (CSS px).
const REACH = 16

export default class extends Controller {
  static targets = [ "svg", "label", "name", "state" ]

  connect() {
    this.outside = (event) => { if (!this.element.contains(event.target)) this.hide() }
    document.addEventListener("click", this.outside, true)
  }

  disconnect() {
    document.removeEventListener("click", this.outside, true)
  }

  over(event) {
    if (event.pointerType === "mouse" && this.isDot(event.target)) this.show(event.target)
  }

  out(event) {
    if (event.pointerType === "mouse" && event.target === this.active && document.activeElement !== this.active) this.hide()
  }

  focus(event) {
    if (this.isDot(event.target)) this.show(event.target)
  }

  blur(event) {
    if (event.target === this.active) this.hide()
  }

  // A press begins, before the focused dot loses focus (which hides its label). A finger is wider than a dot (6px on a
  // phone), so a touch takes the nearest dot within reach. data-map-tap tells the analytics this press is the map's,
  // not a click on the card.
  down(event) {
    this.tapped = this.isDot(event.target) ? event.target : event.pointerType === "mouse" ? null : this.nearest(event)
    if (this.tapped || this.active) this.element.dataset.mapTap = ""
    else delete this.element.dataset.mapTap
  }

  click(event) {
    const mapTap = "mapTap" in this.element.dataset
    const dot = this.isDot(event.target) ? event.target : this.tapped
    delete this.element.dataset.mapTap
    this.tapped = null
    if (dot) {
      event.preventDefault()
      this.show(dot)
    } else if (mapTap || this.active) {
      event.preventDefault()
      this.hide()
    }
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
    if (!this.active) return
    this.active.classList.remove("is-active")
    this.active = null
    this.labelTarget.hidden = true
    delete this.element.dataset.labelOpen
  }

  // From the dot's place in the drawing (not its box, which grows as it animates).
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
