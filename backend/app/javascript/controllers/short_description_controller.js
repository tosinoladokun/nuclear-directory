import { Controller } from "@hotwired/stimulus"

// A company's short description (#559): counts down from 40 and refuses a
// line wider than a phone row has (330px at 14px Roboto Serif), so it never wraps.
export default class extends Controller {
  static targets = ["input", "count", "preview"]
  static values = { max: Number, width: Number }

  connect() {
    this.update()
    // Measured again once Roboto Serif has loaded, not in a fallback font.
    document.fonts?.ready.then(() => this.update())
  }

  update() {
    const text = this.inputTarget.value.trim()
    const left = this.maxValue - text.length
    const wide = this.measure(text) > this.widthValue
    this.countTarget.textContent = wide ? "Too wide for a phone row: shorten it" : `${left} left`
    this.previewTarget.textContent = text || "Role · specialty until it's written"
    this.inputTarget.setCustomValidity(wide ? "Too wide for one line on a phone. Shorten it." : "")
  }

  measure(text) {
    this.canvas ||= document.createElement("canvas")
    const context = this.canvas.getContext("2d")
    context.font = "14px 'Roboto Serif', serif"
    return context.measureText(text).width
  }
}
