import { Controller } from "@hotwired/stimulus"

// The connections map (#363). The server draws it; once the fonts are in,
// this fits each name to its slot and moves any verb that would touch a
// node, a name, another verb or another line. Then hovering, focusing or
// tapping a line fills the details card (a sheet on phones).
//
// Names: shrink 0.5px at a time to the floor, then the short name, then an
// ellipsis (the full name stays in <title>). Verbs: along their line at 50%,
// then 45/55% ... out to 30/70%; level instead of along the line where the
// line is steep; shortened ("sells power") only as a last resort. Each verb
// cuts a 4px gap into its line at both ends.
const OFFSETS = [ 0.5, 0.45, 0.55, 0.4, 0.6, 0.35, 0.65, 0.3, 0.7 ]
const SHORTER = { "sells power to": "sells power" }

export default class extends Controller {
  static targets = [ "figure", "view", "svg", "card", "cardBody", "list" ]

  connect() {
    if (this.hasListTarget) this.listTarget.open = false
    this.pinned = null
    this.done = new WeakSet()
    this.escape = (event) => { if (event.key === "Escape" && !this.cardTarget.hidden) this.close() }
    document.addEventListener("keydown", this.escape)
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
    document.removeEventListener("keydown", this.escape)
    this.observer.disconnect()
  }

  // Each drawing once, when it's first on screen (a hidden one can't be measured).
  layOut() {
    if (!this.fontsReady) return
    this.svgTargets.forEach((svg) => {
      if (this.done.has(svg) || svg.getClientRects().length === 0) return
      this.fitNames(svg)
      this.placeLabels(svg)
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

  placeLabels(svg) {
    const circles = [ ...svg.querySelectorAll(".nd-map__ring") ].map((ring) => ({ x: ring.cx.baseVal.value, y: ring.cy.baseVal.value, r: ring.r.baseVal.value + 6 }))
    // Arrowheads too: a word never butts against one.
    svg.querySelectorAll(".nd-map__line[marker-end]").forEach((line) => {
      const tip = line.getPointAtLength(line.getTotalLength())
      circles.push({ x: tip.x, y: tip.y, r: 12 })
    })
    const names = [ ...svg.querySelectorAll(".nd-map__name") ].map((name) => name.getBBox())
    const points = new Map() // group id → points along its lines, every 4px
    svg.querySelectorAll(".nd-map__edge").forEach((edge) => {
      const list = []
      edge.querySelectorAll(".nd-map__line").forEach((line) => {
        const length = line.getTotalLength()
        for (let at = 0; at <= length; at += 4) list.push(line.getPointAtLength(at))
      })
      points.set(edge.dataset.group, list)
    })
    const placed = []

    svg.querySelectorAll(".nd-map__label--path").forEach((along) => {
      const id = along.dataset.group
      const level = svg.querySelector(`.nd-map__label--flat[data-group="${id}"]`)
      const halo = svg.querySelector(`.nd-map__halo[data-group="${id}"]`)
      const line = svg.getElementById(`${id}-path`)
      const reversed = along.querySelector("textPath").getAttribute("href").endsWith("-rev")
      const length = line.getTotalLength()
      const others = [ ...points.entries() ].filter(([ key ]) => key !== id).flatMap(([ , list ]) => list)
      const clear = (box) => !circles.some((circle) => hitsCircle(box, circle)) &&
        !names.some((name) => overlaps(box, name, 0)) &&
        !placed.some((other) => overlaps(box, other, 4)) &&
        !others.some((point) => inside(point, box))

      const tryAt = (offset) => {
        const at = offset * length
        const steep = isSteep(line, at, length)
        show(steep ? level : along, steep ? along : level)
        halo.style.visibility = steep ? "hidden" : ""
        if (steep) {
          const point = line.getPointAtLength(at)
          level.setAttribute("x", point.x.toFixed(1))
          level.setAttribute("y", (point.y + 4).toFixed(1))
        } else {
          const startOffset = `${((reversed ? 1 - offset : offset) * 100).toFixed(1)}%`
          along.querySelector("textPath").setAttribute("startOffset", startOffset)
          halo.querySelector("textPath").setAttribute("startOffset", startOffset)
        }
        const shown = steep ? level : along
        return { shown, steep, at, box: shown.getBBox() }
      }

      // The first clear spot, leaving the word there.
      const firstClear = () => {
        for (const offset of OFFSETS) {
          const candidate = tryAt(offset)
          if (clear(candidate.box)) return candidate
        }
      }
      let spot = firstClear()
      if (!spot && SHORTER[along.dataset.verb]) {
        along.querySelector("textPath").textContent = halo.querySelector("textPath").textContent = level.textContent = SHORTER[along.dataset.verb]
        along.dataset.shortened = level.dataset.shortened = "true"
        console.warn(`connections map: shortened the verb on ${id}`)
        spot = firstClear()
      }
      if (!spot) {
        spot = tryAt(0.5)
        spot.shown.dataset.collides = "true"
        console.warn(`connections map: the verb on ${id} touches something`)
      }
      placed.push(spot.box)
      cutGap(line, spot, length)
    })
  }

  // The details card: filled while a line is hovered or focused, kept on a click or Enter.
  // On phones the card is a sheet over the map: only a tap or Enter opens it.
  // A hover there would cover the line under the pointer and swallow the click.
  preview(event) {
    if (!this.pinned && !this.returning && !this.sheet()) this.show(event.currentTarget)
  }

  unpreview() {
    if (!this.pinned && !this.sheet()) this.hide()
  }

  sheet() {
    return window.matchMedia("(max-width: 639px)").matches
  }

  pin(event) {
    const hit = event.currentTarget
    if (this.pinned === hit) return this.close()
    this.pinned = hit
    this.show(hit)
  }

  key(event) {
    if (event.key !== "Enter" && event.key !== " ") return
    event.preventDefault()
    this.pin(event)
  }

  close() {
    const back = this.pinned
    this.pinned = null
    this.hide()
    // Focus goes back to the line without opening its card again.
    if (back && document.activeElement !== back) {
      this.returning = true
      back.focus({ preventScroll: true })
      this.returning = false
    }
  }

  show(hit) {
    this.highlight(hit)
    const template = this.element.querySelector(`template[data-card="${hit.dataset.card}"]`)
    if (!template) return
    this.cardBodyTarget.replaceChildren(template.content.cloneNode(true))
    this.cardTarget.hidden = false
  }

  hide() {
    this.highlight(null)
    this.cardTarget.hidden = true
  }

  highlight(hit) {
    this.element.querySelectorAll(".nd-map__edge.is-on").forEach((edge) => edge.classList.remove("is-on"))
    if (hit) hit.ownerSVGElement.querySelector(`.nd-map__edge[data-group="${hit.dataset.group}"]`)?.classList.add("is-on")
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
    // The fold node in whichever drawing is showing (wide or phone).
    const folds = this.element.querySelectorAll(".nd-map__view[data-view=folded] .nd-map__node--fold")
    ;[ ...folds ].find((node) => node.getClientRects().length > 0)?.focus()
  }

  swap(name) {
    this.close()
    this.viewTargets.forEach((view) => { view.hidden = view.dataset.view !== name })
    this.layOut()
  }
}

function show(on, off) {
  on.style.visibility = ""
  off.style.visibility = "hidden"
}

// Steeper than 35° where the word sits: the word goes level instead.
function isSteep(line, at, length) {
  const a = line.getPointAtLength(Math.max(0, at - 6))
  const b = line.getPointAtLength(Math.min(length, at + 6))
  const angle = Math.abs(Math.atan2(b.y - a.y, b.x - a.x) * 180 / Math.PI)
  return angle > 35 && angle < 145
}

// The line stops 4px before the word and starts again 4px after it.
function cutGap(line, spot, length) {
  let from, to
  if (spot.steep) {
    const box = grow(spot.box, 4)
    const inBox = []
    for (let at = 0; at <= length; at += 1) if (inside(line.getPointAtLength(at), box)) inBox.push(at)
    if (inBox.length === 0) return
    from = inBox[0]
    to = inBox[inBox.length - 1]
  } else {
    const half = spot.shown.getComputedTextLength() / 2 + 4
    from = Math.max(0, spot.at - half)
    to = Math.min(length, spot.at + half)
  }
  line.style.strokeDasharray = `${from.toFixed(1)} ${(to - from).toFixed(1)} ${length.toFixed(1)}`
}

function grow(box, by) {
  return { x: box.x - by, y: box.y - by, width: box.width + by * 2, height: box.height + by * 2 }
}

function overlaps(a, b, gap) {
  return a.x < b.x + b.width + gap && b.x < a.x + a.width + gap && a.y < b.y + b.height + gap && b.y < a.y + a.height + gap
}

function inside(point, box) {
  return point.x >= box.x && point.x <= box.x + box.width && point.y >= box.y && point.y <= box.y + box.height
}

function hitsCircle(box, circle) {
  const x = Math.max(box.x, Math.min(circle.x, box.x + box.width))
  const y = Math.max(box.y, Math.min(circle.y, box.y + box.height))
  return Math.hypot(circle.x - x, circle.y - y) < circle.r
}
