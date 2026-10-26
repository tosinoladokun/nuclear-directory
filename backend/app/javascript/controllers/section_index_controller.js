import { Controller } from "@hotwired/stimulus"

// The page's index (#556): the entry for the section in view is marked
// aria-current, as you scroll. A state, not a divider. The sections inside
// the observation band are kept between callbacks (an observer reports only
// changes), and the topmost of them is current, on exits as well as entrances.
export default class extends Controller {
  connect() {
    const links = [...this.element.querySelectorAll(".nd-idx a[href^='#']")]
    const sections = links.map((link) => document.getElementById(link.getAttribute("href").slice(1))).filter(Boolean)
    if (!sections.length || !("IntersectionObserver" in window)) return

    const inView = new Set()
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => (entry.isIntersecting ? inView.add(entry.target) : inView.delete(entry.target)))
      const current = sections.find((section) => inView.has(section))
      if (!current) return

      links.forEach((link) => {
        if (link.getAttribute("href") === `#${current.id}`) link.setAttribute("aria-current", "page")
        else link.removeAttribute("aria-current")
      })
    }, { rootMargin: "-10% 0px -70% 0px" })
    sections.forEach((section) => this.observer.observe(section))
  }

  disconnect() {
    this.observer?.disconnect()
  }
}
