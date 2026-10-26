import { Controller } from "@hotwired/stimulus"

// The page's index (#556): the entry for the section in view is marked
// aria-current, as you scroll. A state, not a divider.
export default class extends Controller {
  connect() {
    const links = [...this.element.querySelectorAll(".nd-idx a[href^='#']")]
    const sections = links.map((link) => document.getElementById(link.getAttribute("href").slice(1))).filter(Boolean)
    if (!sections.length || !("IntersectionObserver" in window)) return

    this.observer = new IntersectionObserver((entries) => {
      const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0]
      if (!visible) return
      links.forEach((link) => {
        if (link.getAttribute("href") === `#${visible.target.id}`) link.setAttribute("aria-current", "page")
        else link.removeAttribute("aria-current")
      })
    }, { rootMargin: "-10% 0px -70% 0px" })
    sections.forEach((section) => this.observer.observe(section))
  }

  disconnect() {
    this.observer?.disconnect()
  }
}
