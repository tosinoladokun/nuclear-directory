import { Controller } from "@hotwired/stimulus"

// Put on a turbo-frame whose contents grow in place ("Show more"). Swapping
// them briefly empties the page, which would scroll it to the top, and removes
// the link that had keyboard focus. So: keep the scroll position, and when
// focus was inside the frame, move it to the first newly shown result (or to
// the frame itself when nothing is new, e.g. the last page), so a keyboard
// user keeps their place and Tab continues from there. "First new" means the
// new result nearest where Show more was on screen: with companies and plants
// both expanding, the first new company would be far above it.
export default class extends Controller {
  connect() {
    this.element.tabIndex = -1
    this.save = () => {
      this.y = window.scrollY
      this.hadFocus = this.element.contains(document.activeElement)
      this.anchorTop = this.hadFocus ? document.activeElement.getBoundingClientRect().top : 0
      this.known = new Set(this.links().map((link) => link.href))
    }
    this.restore = () => {
      window.scrollTo(0, this.y)
      if (!this.hadFocus) return
      const fresh = this.links().filter((link) => !this.known.has(link.href))
        .sort((a, b) => Math.abs(a.getBoundingClientRect().top - this.anchorTop) - Math.abs(b.getBoundingClientRect().top - this.anchorTop))[0]
      const target = fresh || this.element
      target.focus({ preventScroll: true })
      const box = target.getBoundingClientRect()
      if (box.top < 0 || box.bottom > window.innerHeight) target.scrollIntoView({ block: "nearest" })
    }
    this.element.addEventListener("turbo:before-frame-render", this.save)
    this.element.addEventListener("turbo:frame-render", this.restore)
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-frame-render", this.save)
    this.element.removeEventListener("turbo:frame-render", this.restore)
  }

  links() { return [...this.element.querySelectorAll("ul.nd-lines a.nd-line")] }
}
