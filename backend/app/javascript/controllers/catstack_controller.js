import { Controller } from "@hotwired/stimulus"

// The home page's category cards on phones (#362): each card's title is its link to the list, and a caret button beside it
// opens and closes the card, with "Collapse all" / "Expand all" above. Every card starts open; the collapsed ones are
// remembered in this browser. Wide screens never collapse (CSS), and without JavaScript every card stays open.
const KEY = "nd.home.collapsed"

export default class extends Controller {
  static targets = ["card", "head", "all"]

  connect() {
    const collapsed = new Set(this.read())
    this.cardTargets.forEach((card, index) => {
      const head = this.headTargets[index]
      if (!head.querySelector(".nd-catcard__toggle")) this.enhance(card, head)
      this.set(card, !collapsed.has(card.dataset.key))
    })
    this.allTarget.hidden = false
    this.label()
  }

  // A caret button beside the title (once: a page Turbo restores from its cache already has it).
  enhance(card, head) {
    const body = card.querySelector(".nd-catcard__body")
    const button = document.createElement("button")
    button.type = "button"
    button.className = "nd-catcard__toggle"
    button.setAttribute("aria-controls", body.id)
    button.setAttribute("aria-label", card.dataset.name)
    button.setAttribute("data-action", "catstack#toggle")
    button.innerHTML = '<span class="nd-catcard__caret" aria-hidden="true"></span>'
    head.append(button)
  }

  toggle(event) {
    const card = event.currentTarget.closest("[data-catstack-target='card']")
    this.set(card, card.classList.contains("is-collapsed"))
    this.save()
    this.label()
  }

  toggleAll() {
    const open = this.anyOpen()
    this.cardTargets.forEach((card) => this.set(card, !open))
    this.save()
    this.label()
  }

  set(card, open) {
    card.classList.toggle("is-collapsed", !open)
    card.querySelector(".nd-catcard__toggle")?.setAttribute("aria-expanded", String(open))
  }

  anyOpen() {
    return this.cardTargets.some((card) => !card.classList.contains("is-collapsed"))
  }

  label() {
    this.allTarget.textContent = this.anyOpen() ? "Collapse all" : "Expand all"
  }

  read() {
    try {
      return JSON.parse(localStorage.getItem(KEY) || "[]")
    } catch {
      return []
    }
  }

  save() {
    const keys = this.cardTargets.filter((card) => card.classList.contains("is-collapsed")).map((card) => card.dataset.key)
    try {
      localStorage.setItem(KEY, JSON.stringify(keys))
    } catch {
      // Storage blocked (private mode): the choice lasts this visit only.
    }
  }
}
