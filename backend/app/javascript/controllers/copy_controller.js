import { Controller } from "@hotwired/stimulus"

// Copy button (#556): copies the text and says "Copied" for two seconds.
export default class extends Controller {
  static targets = ["text", "label"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textTarget.textContent.trim())
    } catch {
      const range = document.createRange()
      range.selectNodeContents(this.textTarget)
      getSelection().removeAllRanges()
      getSelection().addRange(range)
      document.execCommand("copy")
    }
    this.labelTarget.textContent = "Copied"
    clearTimeout(this.timer)
    this.timer = setTimeout(() => { this.labelTarget.textContent = "Copy" }, 2000)
  }
}
