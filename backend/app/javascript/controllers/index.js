// Register the controllers from the importmap via controllers/**/*_controller, each loaded only when an element on the page uses it
// (#speed): most pages need a handful of the ~30, and loading all of them made ~30 extra requests per page.
import { application } from "controllers/application"
import { lazyLoadControllersFrom } from "@hotwired/stimulus-loading"
lazyLoadControllersFrom("controllers", application)
