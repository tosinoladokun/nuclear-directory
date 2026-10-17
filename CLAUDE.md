# Nuclear Directory

- Before building or changing any view, read `DESIGN.md`. Build screens from the design system's tokens, `type-*` utilities, `nd-*` component classes and the `icon` helper; copy markup from `/design` (`backend/app/views/design_system/show.html.erb`). No hex values or Tailwind palette colors in views.
- Before writing any user-facing text (page copy, headings, buttons, labels, empty states, errors, descriptions), read `VOICE.md` and use the project skills `ux-writing` for interface text and `humanizer` as a final pass on prose. `VOICE.md` overrides the skills where they disagree. The skills are vendored from blader/humanizer@225a6f3 (v3.1.0) and content-designer/ux-writing-skill@98cacde, both MIT.
- Before adding or changing data (seed files, the data quality pipeline, admin decisions, research), read `docs/DATA.md`: what each record and link means, names, units, what counts as a source, and the checks.
- `planning/` (PRD and schema) is gitignored on purpose. GitHub issues must be self-contained.
- Sessions never merge pull requests. Only Tosin merges.
