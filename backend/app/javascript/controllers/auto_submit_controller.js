import { Controller } from "@hotwired/stimulus"

// A select that applies itself: changing it submits its form (the Sort beside Filters on phones, #560).
// Without JavaScript the form's own button does it.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
