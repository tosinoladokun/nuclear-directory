import { Controller } from "@hotwired/stimulus"

// An old link to a row that moved to another page (#source-12 on Sources,
// now on Overview) goes to that row there. Only when this page has no
// element with that id, so a row still here is never redirected.
export default class extends Controller {
  static values = { pattern: String, to: String }

  connect() {
    const id = decodeURIComponent(window.location.hash.slice(1))
    if (!id || !new RegExp(this.patternValue).test(id) || document.getElementById(id)) return

    window.location.replace(`${this.toValue}#${encodeURIComponent(id)}`)
  }
}
