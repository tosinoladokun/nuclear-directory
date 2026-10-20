// Tosin's rule (DESIGN.md, #365): text inside a box never wraps, and a source
// number never starts a line on its own. Returns what breaks it, as strings.
(() => {
  const ONE_LINE = ".nd-bucketchip, .nd-btn, .nd-pill, .nd-tag, .nd-sugg, .nd-cat__name, .nd-cat__examples, .nd-listrow__name, .nd-listrow__desc, .nd-catcard__name, .nd-catcard__rowname, .nd-catcard__more, .nd-sitechip, .nd-overview__line--fit, .nd-overview dd a:not(.nd-src), .nd-home .nd-suggs"
  // Lines of text: text rects grouped by vertical overlap, so a smaller
  // count or a chip beside the text doesn't count as a line of its own.
  const lines = (el) => {
    const rects = []
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    let node
    while ((node = walker.nextNode())) {
      if (!node.textContent.trim()) continue
      const range = document.createRange()
      range.selectNodeContents(node)
      rects.push(...[...range.getClientRects()].filter((r) => r.width > 0))
    }
    rects.sort((a, b) => a.top - b.top)
    let count = 0
    let bottom = -Infinity
    for (const r of rects) {
      if (r.top >= bottom - 2) { count++; bottom = r.bottom } else bottom = Math.max(bottom, r.bottom)
    }
    return count
  }
  const visible = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== "hidden" }
  const problems = []
  const label = (el) => `${el.className.split(" ")[0]} "${el.textContent.trim().replace(/\s+/g, " ").slice(0, 50)}"`
  document.querySelectorAll(ONE_LINE).forEach((el) => {
    if (!visible(el)) return
    if (lines(el) > 1) problems.push(`wraps: ${label(el)}`)
    // Never clipped top or bottom (DESIGN.md one-line law, rules 5 and 6): a
    // glyph's box (its Range rect) stays inside every clipping box around it
    // here, so descenders in "X-energy" show. scrollHeight can't see this:
    // it measures line boxes, not glyphs.
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.textContent.trim()) continue
      const range = document.createRange()
      range.selectNodeContents(node)
      const glyphs = range.getBoundingClientRect()
      if (glyphs.width === 0 && glyphs.height === 0) continue // not drawn (a hidden short label)
      for (let box = node.parentElement; box && el.contains(box); box = box.parentElement) {
        if (getComputedStyle(box).overflowY === "visible") continue
        const edge = box.getBoundingClientRect()
        if (glyphs.top < edge.top - 0.5 || glyphs.bottom > edge.bottom + 0.5) { problems.push(`clips top or bottom: ${label(box)}`); break }
      }
    }
    // Cut short: allowed only where marked data-truncate, and then the full
    // text must be in title (an ellipsis is the last resort, #365).
    // A row that scrolls inside itself (the phone suggestions) isn't cut short.
    if (["auto", "scroll"].includes(getComputedStyle(el).overflowX)) return
    // Cut short: the box overflows, or its own text runs past it (an
    // ellipsis can leave scrollWidth equal to clientWidth).
    const own = [...el.childNodes].filter((node) => node.nodeType === Node.TEXT_NODE && node.textContent.trim())
    const textRight = own.reduce((right, node) => { const range = document.createRange(); range.selectNodeContents(node); return Math.max(right, range.getBoundingClientRect().right) }, -Infinity)
    if (el.scrollWidth > el.clientWidth + 1 || textRight > el.getBoundingClientRect().right + 1) {
      if (!el.hasAttribute("data-truncate")) problems.push(`cut short: ${label(el)}`)
      else if (el.getAttribute("title") !== el.textContent.trim()) problems.push(`no full text in title: ${label(el)}`)
    }
  })
  // Key facts (DESIGN.md "Components and alignment", #406). A value beside its
  // label starts on the value column's edge; a stacked value, and every value
  // under 480px, starts on the label's edge (a hung Type pill by its icon).
  // Label to value is 4px when stacked; row to row is 12px. Within 1px.
  document.querySelectorAll(".nd-overview dl").forEach((dl) => {
    if (!visible(dl)) return
    const pairs = [...dl.querySelectorAll(":scope > dt")].map((dt) => ({ dt, dd: dt.nextElementSibling })).filter(({ dd }) => dd && dd.matches("dd"))
    // Where a value's first glyph is drawn (its icon, for a chip): padding, margin
    // or an indent on the value moves this, not the box around it.
    const start = (el) => {
      const chip = el.querySelector(".nd-bucketchip")
      if (chip) return chip.getBoundingClientRect().left + parseFloat(getComputedStyle(chip).paddingLeft)
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (!node.textContent.trim()) continue
        const range = document.createRange()
        range.selectNodeContents(node)
        const rect = [...range.getClientRects()].find((r) => r.width > 0)
        if (rect) return rect.left
      }
      return el.getBoundingClientRect().left
    }
    let valueEdge = null, previous = null
    pairs.forEach(({ dt, dd }) => {
      const name = dt.textContent.trim(), t = dt.getBoundingClientRect(), d = dd.getBoundingClientRect()
      // The layout is expected from the class and the viewport, not read off the geometry.
      const stacked = dt.classList.contains("nd-overview__stack") || window.innerWidth < 480
      if (stacked !== (d.top >= t.bottom - 1)) problems.push(`${stacked ? "should be stacked" : "should sit beside its label"}: ${name}`)
      if (stacked) {
        if (Math.abs(start(dd) - start(dt)) > 1) problems.push(`value off its label's edge: ${name}`)
        if (Math.abs(d.top - t.bottom - 4) > 1) problems.push(`label to value is not 4px: ${name} (${Math.round(d.top - t.bottom)})`)
      } else {
        const edge = start(dd)
        if (valueEdge === null) valueEdge = edge
        else if (Math.abs(edge - valueEdge) > 1) problems.push(`value off the value column's edge: ${name}`)
      }
      if (previous && Math.abs(Math.min(t.top, d.top) - previous - 12) > 1) problems.push(`row gap is not 12px before: ${name} (${Math.round(Math.min(t.top, d.top) - previous)})`)
      previous = Math.max(t.bottom, d.bottom)
    })
  })
  document.querySelectorAll(".nd-src").forEach((chip) => {
    if (!visible(chip)) return
    // Numbers in the sources line wrap as whole numbers after the first one.
    if (chip.parentElement.matches(".nd-overview__sources") && chip.previousElementSibling?.matches(".nd-src, .nd-keep")) return
    let prev = chip.previousSibling
    while (prev && prev.nodeType === 3 && !prev.textContent.trim()) prev = prev.previousSibling
    if (!prev) {
      const parent = chip.parentElement
      if (parent && parent.matches(".nd-overview__cites, .nd-keep") && parent.previousSibling) prev = parent.previousSibling
      else return
    }
    const range = document.createRange()
    range.selectNodeContents(prev.nodeType === 3 ? prev.parentNode : prev)
    if (prev.nodeType === 3) range.selectNode(prev)
    const rects = [...range.getClientRects()].filter((r) => r.width > 0)
    if (!rects.length) return
    const last = rects[rects.length - 1]
    const chipTop = chip.getBoundingClientRect().top
    if (chipTop > last.bottom - 2) problems.push(`number alone: ${chip.textContent.trim().slice(0, 6)} after "${(prev.textContent || "").trim().slice(-30)}"`)
  })
  if (document.documentElement.scrollWidth > window.innerWidth) problems.push(`scrolls sideways: ${document.documentElement.scrollWidth} > ${window.innerWidth}`)
  return problems
})()
