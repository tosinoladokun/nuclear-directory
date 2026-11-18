import { Controller } from "@hotwired/stimulus"

// Inbox multi-select (#771): the action bar shows once a row is ticked, with
// the count. Shift-click ticks a range; x ticks the row under the focus.
export default class extends Controller {
  static targets = ["box", "bar", "count"]

  connect() {
    this.onKey = (event) => {
      if (event.key !== "x" || event.metaKey || event.ctrlKey || event.altKey) return
      if (event.target.closest("input[type=text], textarea, select, [contenteditable]")) return
      const box = event.target.closest("li")?.querySelector("input[name='selected[]']")
      if (!box || !this.boxTargets.includes(box)) return
      event.preventDefault()
      box.checked = !box.checked
      this.last = box
      this.update()
    }
    document.addEventListener("keydown", this.onKey)
    this.update()
  }

  disconnect() { document.removeEventListener("keydown", this.onKey) }

  pick(event) {
    const box = event.currentTarget
    if (event.shiftKey && this.last) {
      const [a, b] = [this.boxTargets.indexOf(this.last), this.boxTargets.indexOf(box)].sort((x, y) => x - y)
      this.boxTargets.slice(a, b + 1).forEach((other) => { other.checked = box.checked })
    }
    this.last = box
    this.update()
  }

  all(event) {
    const section = event.currentTarget.dataset.section
    this.boxTargets.filter((box) => box.dataset.section === section).forEach((box) => { box.checked = event.currentTarget.checked })
    this.update()
  }

  update() {
    const count = this.boxTargets.filter((box) => box.checked).length
    this.countTargets.forEach((target) => { target.textContent = count })
    this.barTarget.hidden = count === 0
  }
}
