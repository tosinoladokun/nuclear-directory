# DataQuality

The workflow that fills the directory from public sources:

```
crawl → extract → match → verify → publish / review
```

It is a self-contained module (decision in #1) so it can later move to its
own service or repo without rewrites.

## The boundary

- **Owns:** `sources`, `crawl_runs`, `candidates` (models `Source`, `CrawlRun`, `Candidate`).
- **Reads** directory data only through `Directory::Lookup`.
- **Writes** facts and evidence only through `Directory::FactWriter`.
- Both calls live in one file, [`directory_client.rb`](directory_client.rb). Nothing
  else in the module may name directory models or `Directory::` code.

`test/data_quality/boundary_test.rb` enforces this and fails CI on a violation:
a directory model (`Organization`, `Evidence`, …), `Directory::` outside
`directory_client.rb`, `.subject` (which loads a directory record), or
`constantize`.

## Layout

| File | What it is |
|---|---|
| `pipeline.rb` | Runs stages in order, or just some of them |
| `stage.rb`, `stages/` | One class per stage. Each run is a `crawl_runs` row |
| `plugin.rb`, `plugins/` | One plug-in per `source_kind`: its crawl and extract logic |
| `verdict.rb`, `verifiers/` | Verify outcomes. Default sends everything to review until #15 |
| `directory_client.rb` | The only door into the directory |
| `open_router/client.rb` | LLM calls with JSON-schema output, retries, token accounting |
| `config.rb` | Settings from env (`OPENROUTER_*`) |
| `run_job.rb` | Background job (Solid Queue, queue `data_quality`) |

Tests live in `test/data_quality/`. They use a fake directory
(`support/fake_directory.rb`) and a dummy plug-in, and never make real HTTP calls.

## Running it

```bash
docker compose run --rm web bin/rails "data_quality:run[nrc_reactor_list]"
```

```bash
docker compose run --rm web bin/rails "data_quality:stage[extract,nrc_reactor_list]"
```

Or from code: `DataQuality::RunJob.perform_later("nrc_reactor_list", only: "extract")`.
The quotes stop zsh from treating `[...]` as a file pattern.

**In production it runs every day (#53):** `config/recurring.yml` queues `DailyCrawlJob` at 3am US
Eastern (Solid Queue's scheduler, inside Puma via `SOLID_QUEUE_IN_PUMA`). It runs the whole
pipeline for `nrc_reactor_list`, then for `eia_generators`, so EIA always starts after NRC has
finished; if one source fails, the other still runs and the job is marked failed. Each source is
fetched at most once a day. A blocked fetch is recorded (blocked, then needs_human after 3 days);
what happens next depends on the plug-in: NRC goes on with nothing new, while EIA stops, since it
can't find the month's file without its index page. Verify only recommends: nothing is published
until a person approves it in the admin. Results are in
`crawl_runs` and on the admin's Sources and runs page.

To see how it's doing (blocked sources, last runs, review queue, model spend):

```bash
docker compose run --rm web bin/rails data_quality:status
```

**Guards (#81):**
- **One run per source kind at a time.** `Pipeline.run` holds a Postgres advisory lock, and a second
  run stops with `Pipeline::AlreadyRunning`. `RunJob` also limits concurrency per source kind in Solid Queue.
- **No crawl during a data deploy (#301).** Every run also holds the `data_quality:writes` lock shared
  (`WriteLock`), so runs of different kinds still overlap. A deploy's data steps take it alone:
  `TASKS="seed:check db:seed" bin/rails data_quality:with_write_lock` waits for running crawls (up to
  `WAIT_MINUTES`, default 30), then runs the tasks in that one process. A crawl that starts meanwhile stops
  with `AlreadyRunning` and is retried.
- **No stuck runs (#188).** Every run is made inside its source kind's lock, so a run of that kind still
  "running" while the lock is held belongs to a process that died (a restart, or running out of memory).
  Each run first marks those as failed ("Abandoned…"). In production the hourly `CatchUpJob` does the same
  for every kind not mid-run, and queues today's daily crawl again, once a day per source, from the first
  source whose run was cut off (or that hasn't run by 4am Eastern).
- **Re-run without fetching.** `bin/rails "data_quality:rerun[nrc_reactor_list]"` queues extract, match and
  verify from the stored snapshot for the background worker (not in the shell's own process, which on
  Render would share the instance's memory).
- **Key check.** `bin/rails data_quality:check_key` asks OpenRouter whether the key works, with no model
  call and no cost, and prints its usage and limit. A refused key fails runs with "OpenRouter rejected the
  API key: check OPENROUTER_API_KEY".
- **Spend guard.** Before every model call, this month's model cost (from `crawl_runs.stats`) is checked
  against `DATA_QUALITY_MONTHLY_BUDGET` (default $5; a non-number or negative value is a configuration
  error). Once it's used up, calls are refused with `Budget::Exceeded` and the run fails with that
  reason. It's a soft limit: calls already in flight still finish, so spend can pass it by a fraction
  of a cent per concurrent run. The OpenRouter key's own credit limit is the hard stop.

## Adding a source

Create `plugins/<source_kind>.rb` defining `DataQuality::Plugins::<SourceKind> < DataQuality::Plugin`
with `crawl(run)` and `extract(source, run)` (see `plugin.rb`). Match and verify are shared.

Fetch with `DataQuality::Snapshot.take(source, fetcher: DataQuality::Fetcher.new)`, never your own HTTP:
- **`Fetcher`** identifies as `NuclearDirectoryBot` with a contact address (`CONTACT_EMAIL`), obeys robots.txt, waits between requests to a host,
  sends ETag / If-Modified-Since, and never retries. It fetches public https only: the standard port,
  redirects that stay on the same host (with or without `www.`), and hosts that resolve only to public
  addresses (no private, loopback, link-local or metadata IPs); it connects to the address it checked.
  Anything else comes back as `:error`, "Not fetched: …".
- **`Snapshot`** fetches a source at most once a day and records the result on it: content and hash,
  `blocked` with the CDN reference on a 403 (`needs_human` after 3 in a row), or `needs_human` if
  robots.txt disallows it.
- **Extract skips** sources whose content hash hasn't changed since the last extraction.
- **Titles:** a fetched HTML page's `<title>` (or `og:title`) becomes `sources.title`. For sources that
  were never fetched (e.g. the hand-checked seed), run the one-off
  `bin/rails data_quality:backfill_titles`: one polite, conditional fetch per untitled URL (never a second fetch of a source on the same day), keeping only the title.
  A page without one (a PDF) gets "site, date", and a block leaves the title empty.

Never work around a block. `plugins/nrc_reactor_list.rb` is the reference plug-in.

## What extract produces

`extract(source, run)` returns candidate hashes, which the extract stage saves to `candidates`:

| Key | What it is |
|---|---|
| `kind` | One of `Candidate::KINDS`: the six FactWriter kinds plus `organization_alias` |
| `payload` | String keys. Records use FactWriter attribute names. Links name each end with a nested hash (`"organization" => { "name" => … }`, `"facility" => { "name" => …, "nrc_docket" => … }`), never `*_id`; match resolves those |
| `quote` | The supporting text, copied exactly from the source |
| `status`, `notes` | Optional: `status: "needs_review"` with the reason in `notes` sends a candidate straight to review. The stage marks it `review_origin: "extract"`, so re-extracting a changed source replaces it (with the source's `new` candidates) instead of piling up duplicates |

The extract stage adds `source_id` and `crawl_run_id`. Candidates start `new` (or `needs_review` if
the plug-in flagged them). Match links the ones it can to directory records (`matched`). Verify then
recommends or sends to review; a human publishes (`merged`) from the admin. See "Matching and
candidate payloads" below for match's outcomes.

## A fact is decided once (#240)

A nightly crawl doesn't put facts back in the review queue when they haven't changed.

- **Extract** skips a source whose rows haven't changed (`plugin.rows_sha256`; for NRC, the
  table's rows only, since the page has a date stamp). The facts those rows support (approved
  or confirmed from them) get their evidence stamped as checked when the source was fetched.
  Nothing is stamped after a failed fetch, which keeps the old content. A row that repeats a
  claim (a company on several rows) is proposed once.
- **Match** compares a candidate with the decided fact it's attached to
  (`Directory::FactWriter.confirm`):
  - **Same values, and the fact already has evidence from this source:** the candidate
    closes as `confirmed` and the evidence is stamped. There's no review item and no
    history event. This also covers a fact a person rejected or unpublished, which stays as
    decided.
  - **A value a person overruled** (Tosin corrected a state and the source still says the
    old one) doesn't count as a difference. The note says the person's decision stands.
  - **Anything else** stays `matched`, and verify sends a disagreement to review with both
    values, as before.
  - **A pending fact a candidate is already waiting for:** the repeat closes as
    `confirmed`, so the queue holds it once.
- **Dropped:** a published fact that a complete read no longer lists gets one
  `needs_review` item (`review_origin: "dropped"`), never an automatic unpublish.
  - It only runs after a complete read: the snapshot was extracted, and every row was
    placed. A blocked fetch flags nothing.
  - It only covers facts approved or confirmed from that source.
  - A read that would drop more than a quarter of them flags nothing (`plugin.max_dropped_share`; NRC
    decommissioning's site pages, a few facts each, allow any share).
  - `plugin.dropped(kind)` suggests the change. For NRC, a unit gone from the operating
    list is suggested as shut down.

`bin/rails data_quality:confirm_identical` (`BY=human:…`, a dry run unless `APPLY=1`) closes
open candidates the same way. It covers the ones from before this change.

## Verify recommends; a human publishes

Tosin approves everything that goes public. Verify (`stages/verify.rb`) never writes to the directory.
For each `new` or `matched` candidate:

1. **Code checks first**, with no model call. These go to `needs_review`, with the reason in `notes`:
   - its record was rejected or unpublished by a human after match attached it
   - it disagrees with a human-verified value on its record ("human-verified state is NJ; this source
     says DE"; names aren't compared). Not when every value it changes was last written by an
     unedited approval from the same kind of source (`Differences.written_by_person`): the source is
     updating its own value, so the verifier checks it. A seed, an admin edit, a repair, a merge, an
     edited approval or another source makes a value a person's, and one such value keeps the whole
     claim a conflict
   - its quote isn't in the source as stored. Each plug-in defines that: `quote_in_source?`, by default
     the page's visible text, and for NRC a whole table row
   - its plug-in holds it for a person (`hold_for_review`), e.g. a unit NRC lists as decommissioning whose
     owner plans a restart
2. **The verifier agent** (`Verifiers::Agent`, `OPENROUTER_VERIFY_MODEL`, prompt `verify-v3`) reads the
   claim (`Claim.describe`) against an excerpt (`verification_context`; for NRC the header and the row),
   15 claims per call. All model calls happen before anything is written. A plug-in can also say what its
   source states as a whole (`source_facts`). For example, every row of NRC's list is an operating US power
   reactor, and EIA's file is only nuclear units. The model treats that as part of every excerpt, so a claim
   isn't held back because its row doesn't repeat it.
   - "contradicted" needs the different value the source gives (`source_value`); without one, or naming
     the claim's own value (numbers compared at the claim's precision), it's "couldn't confirm"
   - supported and at least 80% sure: **`ai_recommendation: "recommend_publish"`**; the candidate stays
     `new`/`matched` and the fact stays pending
   - anything else: `needs_review`, with the model's reason
   - it never rejects on its own

The recommendation lives on the candidate: `ai_recommendation`, `ai_reason`, `ai_confidence`, `ai_model`,
`ai_checked_at` and `verify_run`. `Candidate.recommended` lists those waiting for approval, indexed by
recommendation and run.

### Safe classes (`safe_classes.rb`, #306 option A)

"Accept recommendations" on Checks also takes the verifier's own recommendations in a **safe class**:
kinds of update that can't change anything a person decided. The classes and their limits are in
`config/safe_verifier_classes.yml`, which Data Quality owns. Each class is off until a PR there turns it
on and Tosin merges it; while off, the preview shows its items as "Would be safe". A claim is safe only
if every gate holds:
- **G1** the verifier recommends it now, with at least the class's confidence (S1: 0.9)
- **G2** it updates an existing published record (S1: a DOE `funds` link a person verified, both
  companies public); it never creates one
- **G3** it changes only the class's fields (S1: description, started on), each last written by the
  pipeline from the same kind of source (`Differences.pipeline_written?`)
- **G4** nothing else is open on its record: no claim waiting for review, no unresolved correction report
- **G5** not from its source's first batch; the latest crawl and match attempts (whatever their status)
  succeeded, and the match checked the claim's own source for dropped facts (`dropped_checked_source_ids`
  in the run's stats; a run skips sources with a claim still to place); the last fetch returned 200, both the claim's page
  and, for S1, the USAspending API index
- **G6** its run proposes no more safe changes than the cap (20, and 25% of the source's public facts),
  counting what the run already had approved; and the source's latest verify run has succeeded (a failed
  or cut-off run keeps a partial set)

S1 also leaves out an award total that may drop by more than 20%: the summaries round ("$1.3 million"),
so the drop is judged at its largest. Accept asks every gate but the cap again
under the record's lock, and records "Accepted the verifier's recommendation (safe class S1: …)" as
Tosin's decision. One fingerprint covers Data Quality's list and the safe items.

## Review: how a human decides (`review.rb`, #85)

The admin (#86) calls only `DataQuality::Review`; it never touches candidates, FactWriter or directory
models. Every action takes `by: "human:…"` (anything else raises) and returns results with `errors`
rather than raising, e.g. when an edit would duplicate another fact.

| Call | What it does |
|---|---|
| `candidates(queue: :recommended \| :needs_review, run_id:, reason:)` | What to decide on, oldest first. Each item has the claim, quote, source, the AI's recommendation and, for a conflict, `differences` (`{ "state" => ["NJ", "DE"] }`, human-verified vs this source) |
| `reasons(queue:, run_id:)` | Kinds of question in a queue, for the reason filter |
| `approve(ids, by:)` | Publishes each in one FactWriter write as a human (not protected): the fact, its evidence (the verifier's confidence, the verify run) and `verification: { status: "verified", by:, context: { candidate_id, crawl_run_id } }`. An approved unit fills its site's blank fields |
| `edit_and_approve(id, attributes:, by:)` | Changes values, then approves. Link ends and slug can't be edited; a failed publish keeps the original values |
| `reject(ids, by:, reason:)` | Rejects candidates, and the record match proposed only for one of them |
| `pending_facts(kind:)` | Directory facts waiting for a human that no open candidate covers (e.g. seed facts loaded as pending), with their evidence's sources |
| `approve_fact`, `reject_fact`, `unpublish(type:, id:, by:, reason:)` | Decide on a directory fact. `approve_fact` takes edited `attributes` and also republishes |
| `history(type:, id:)` | Every decision on a fact, newest first |

Candidates record `reviewed_by` / `reviewed_at`; facts record each decision in the audit trail.

**NRC extract.** The extractor model (`OPENROUTER_EXTRACT_MODEL`, prompt `nrc-extract-v1`) reads the
reactor table as plain lines and returns each unit with its row quoted. Every answer is checked
against the exact parse of the table, by docket. Candidates always carry the table's values; a unit
the model got wrong, misquoted or skipped goes to review with both values in `notes`, and units it
invents are dropped. The tally is in the extract run's `stats["ai_check"]`, so the model's accuracy
is measured on a source we can check before it's trusted on messier ones. Per unit: the unit
(`facility`), its operator (`organization`, one per name) and an `operates` link. A unit carries no
`state` (#197): NRC's Location measures from a nearby city, which near a border is in another state
(Salem and Hope Creek are in NJ, listed from "Wilmington, DE"; Catawba SC, from Charlotte NC; Fermi 2 MI,
from Toledo OH). The state comes from EIA's plant state (Tosin, 2026-10-10). A unit already approved
with NRC's state is corrected, as a recorded decision with its reason, by
`BY=human:<handle> bin/rails "data_quality:correct_unit_state[<docket>,<STATE>]"`.

## NRC decommissioning (#274)

`plugins/nrc_decommissioning.rb` reads NRC's list of power reactor sites undergoing decommissioning,
then NRC's page for each site it links to (about 20), each at most once a day. A block stops the crawl.

- **From the list:** one unit per row, with its docket, `power_reactor`, status `decommissioning` (as the
  list states), and city and state from its Location. The quote is the row. NRC's "Crystal River – Unit 3"
  becomes "Crystal River 3", as NRC's operating list names units, with NRC's spelling as an alias. No
  model is asked. A unit of a known site ("Dresden 1") goes under it, as for the operating list. A plant
  listed with several units (Indian Point, San Onofre) gets a site, proposed first so its units go under
  it and it counts as one plant.
- **From each site page:** NRC names the licensee in prose, so the extractor model (prompt
  `nrc-decommissioning-licensees-v1`) lists the companies that hold the license now, each with the
  sentence that says so. A quote that isn't on the page, or doesn't name the company, sends the claim to
  review. Each licensee gives a company, an `operates` or `owns` link to the page's units, and, only where
  the page says it took over the license to decommission the site, the `waste_decommissioning` category.
- **Restart plans:** Crane and Duane Arnold are on the list while their owners plan a restart. They're
  proposed as decommissioning and held for a person, with the owner's announcement in the note
  (`RESTART_PLANS`). A restart plan is a note, never a status. Approving one also shows its site as
  Decommissioning. They come in as units under their sites ("Crane 1", "Duane Arnold 1"); a site never
  takes a unit's docket.
- **TMI-2** is held too (`PLACE_BY_HAND`): Crane is TMI-1 renamed, so TMI-2 is its own record, never
  under Crane.
- **Blocked site pages:** a list fetched while a site page it links has no readable copy isn't extracted
  (`SitePagesUnread`), so no unit comes in without its licensees. Nothing is written, and a later run
  extracts it once every page has been read.
- **Pages and units leaving the list:** nothing is rejected or retired automatically. A page the list stops
  linking, or a unit moved off a page, sends its open claims to review with a note (`review_origin:
  "withdrawn"`, which a read of the page doesn't replace). Each published link it supported gets one review
  item, as the dropped check does. If the list states them again, the withdrawn claims go back to where
  match left them, with what they proposed, and the page is read again.
- **A page that names a new licensee:** the old published link gets a review item (any share of a site
  page's facts may be flagged), and stays published until a person decides.
- **Pages someone cited by hand** become this plug-in's, so their licensees are read; a page another
  plug-in reads isn't fetched here and holds the list.
- A unit gone from the list is suggested as shut down. The list's rows, and each page's text without its
  date stamp, are what's hashed (#240).


The contract is in [`app/directory/README.md`](../directory/README.md).
`directory_client.rb` uses `Directory::Lookup.organization` / `.facility` and
`Directory::FactWriter.write(kind, attributes, evidence: [...], verification: {...})`.

Two tests keep the module and the directory in step:
- `directory_client_test.rb` runs `DirectoryClient`, and the whole pipeline,
  against the real directory classes.
- It also checks that the fakes in `support/fake_directory.rb` have the same
  method signatures as the real interfaces.

## NRC uranium recovery (#275)

`plugins/nrc_uranium_recovery.rb` reads NRC's "Locations of Uranium Recovery Facilities" once a day, and
only its table of NRC-licensed facilities. Each row gives the site (in situ recovery as `uranium_mine`, a
conventional mill as `mill`; city and state from Location), its licensee, an `operates` link and the
licensee's `mining` category, all quoting the row. A row whose type or state can't be read is held for a
person at verify; a row missing any value holds the whole read. The page's table of Agreement-State sites isn't read: NRC says it was last updated in
2018 and makes no claim about it. Those sites come from each state's own list (#384).

## NRC research and test reactors (#387)

`plugins/nrc_research_reactors.rb` reads the "Locations of Research and Test Reactors" table on NRC's non-power
page (an index, never extracted) and each reactor page it links, at most once a day. It stores the page's name
for the reactor and its Docket Number and Reactor Type, with the table's licensee and location; never contacts.
Each gives the reactor (`research_reactor`, docket, city, state), its licensee, and `university` or
`national_lab` only where the licensee's name says so. No operates link and no power level. The medical isotope
and advanced reactor tables aren't read.
## NRC fuel cycle facilities (#386)

`plugins/nrc_fuel_cycle.rb` reads NRC's fuel cycle locations page (an index, never extracted) and each
facility page it links, at most once a day, storing only the facility's labelled facts (name, location,
licensee, docket, type, status). Each gives the facility (`enrichment` or `fuel_facility`, city, state, docket)
and its licensee. Only an operational facility adds the licensee's `operates` link and the fuel stage its type
states (`enrichment`, `conversion`, `fabrication`). No capacity; no model.

## DOE Isotope Program: production sites (#276)

`plugins/doe_isotope_sites.rb` reads one page, isotopes.gov's "DOE IRP Production Sites", once a day.
It takes names only from the page's own sentences: each lab named as "<Name> National Laboratory (ABBR)"
(or Y-12's "National Security Complex") in a sentence about producing or processing isotopes, and each
school in the sentence listing DOE's University Isotope Network. Each gives a company (its abbreviation as
an alias), the `isotopes` category and, where its own name says so, `national_lab` or `university`, quoting
that sentence. Verify holds a university's isotopes claim for a person (`hold_for_review`, after match
attached it), since network membership alone doesn't say it produces isotopes. No model is asked. Companies DOE names in its news come in a second part.


Sources belong to this module. Code outside it (e.g. the seed loader) gets one
with `DataQuality::Sources.find_or_create(url:, source_kind:, published_on:)`,
which returns a result: `ok?` with a plain `SourceRef` in `ref`, or `errors`. Only absolute http(s)
URLs are accepted (no `javascript:`, `data:` or relative paths), since sources are shown as links.

## Matching and candidate payloads

Extract writes `candidates` (`kind`, `payload`, `quote`, `source_id`). Match
([`stages/match.rb`](stages/match.rb)) then links each one to the directory:

| Outcome | When | Candidate becomes |
|---|---|---|
| **Same brand** | a company name that, without its legal words and a trailing plant or region name, is the brand of exactly one company ("Constellation Energy Generation, LLC" → Constellation; "NextEra Energy Seabrook, LLC" → NextEra Energy) | `matched` to that company, like **Found**. It must agree with the domain. A brand shared by two companies goes to review, even when the domain matches one of them. |
| **Found** | exact NRC docket, domain, or name/alias (normalized) | `matched`, subject = that record. Nothing is written yet: when a human approves it, the quote is added as evidence and an organization gains the name as an alias (its own name is kept). If it disagrees with a human-verified value, verify sends it to review with both values; approving it then applies the new value, since the approver is a human. A record that was rejected or unpublished is never changed or attached to: the candidate goes to review, with who decided and when. |
| **Not found** | nothing exact and nothing similar | `matched`, subject = a new **pending** record with the quote as evidence. A per-plant or regional company name with no company for its brand yet is proposed under its brand ("NextEra Energy Point Beach, LLC" → a new "NextEra Energy"), so later names of the same brand find it. |
| **New unit of a known site** | an NRC unit (has a docket) whose only similar record is a site (no docket, no parent) that covers it | `matched`, subject = a new **pending** unit with `parent_id` = the site |
| **Ambiguous** | identifiers point at different records, or a similar record exists | `needs_review`, with the reason in `notes`. Never merged automatically. |

A link claim that went to review because a company or plant had no exact match ("to_organization: no
exact match for …", "… isn't in the directory yet") is **matched again** on a later run once every end
has an exact one: a name, an alias or an id, never a domain, brand or similar name. It's then an ordinary
claim, verified and approved by a person; nothing is approved on its own. Dropped and extracted review
items, and claims with an end still in question, stay as they are.

A link claim that would change a link which already cites **another page of the same kind of source**
goes to review instead of attaching ("… already cites …, another page of this source"), because
approving it would replace what that page says: two USAspending recipients that are one company each
describe only their own awards (#390). A page that only restates the link isn't held.

"Similar" means the same leading distinctive word, ignoring unit numbers and
generic words ("Vogtle 3" vs "Plant Vogtle Units 3 & 4", "Southern Nuclear
Operating Co." vs "Southern Company"). Facilities with different NRC dockets
are never similar, so "Braidwood 2" isn't flagged against "Braidwood 1".
Plant names for the brand rule come from the facility records (rejected ones
left out); a few brands are their own company and never merged into another
("Southern Nuclear" isn't Southern Company). Rules in
[`Directory::Lookup`](../directory/lookup.rb) (`brand_key`, `brand_name`).

Evidence from match is `found_by: crawler` with no confidence; when a human
approves, the evidence gets the verifier's confidence (if it recommended publishing).

Facilities are matched first, then organizations (so a company name can be
checked against plants proposed in the same run), then links, which can find
records proposed a moment earlier.

**Units and sites.** The seed names plants at site level ("Plant Vogtle", no
docket); the NRC lists units ("Vogtle 3", with a docket). A site covers the
units its name lists ("Palisades Pioneer Units 1 & 2" covers 1 and 2); a name
that lists none ("Plant Vogtle", "Susquehanna Steam Electric Station") covers
every unit. A unit the site doesn't cover ("Palisades" against "Palisades
Pioneer Units 1 & 2"), or with more than one possible site, goes to review.
When a human approves a unit, its `state`, `facility_type`, `status` and `country_code`
fill the site's **blank** fields only (FactWriter `fill_blank: true`), with
the unit's quote as evidence; the site's verification is left alone. If the
unit disagrees with a human-reviewed site (e.g. a different state), nothing is
filled and the candidate notes why; the unit stays published.

**Payloads.** Records carry their attributes, as named in the
[FactWriter table](../directory/README.md#kinds). Links name each end with a
nested hash that identifies it (organizations by `name` and/or `domain`,
facilities by `name` and/or `nrc_docket`):

```ruby
{ kind: "organization", payload: { "name" => "Southern Nuclear Operating Co." } }
{ kind: "facility", payload: { "name" => "Vogtle 3", "nrc_docket" => "05200025",
  "facility_type" => "power_reactor", "status" => "operating", "reactor_type" => "PWR", "state" => "GA" } }
{ kind: "facility_relationship", payload: {
  "organization" => { "name" => "Southern Nuclear Operating Co." },
  "facility" => { "name" => "Vogtle 3", "nrc_docket" => "05200025" },
  "relationship_type" => "operates" } }
{ kind: "organization_role", payload: { "organization" => { "name" => "…" }, "role" => "operator" } }
{ kind: "relationship", payload: { "from_organization" => { "name" => "…" },
  "to_organization" => { "name" => "…" }, "relationship_type" => "supplies" } }
```

A link whose end isn't found, or is itself in review, goes to `needs_review`
too. `organization_alias` candidates aren't matched automatically yet.

## Enrichment sources

Some sources only add values to records NRC already defines. **EIA**
(`plugins/eia_generators.rb`, #61) adds net summer capacity (`capacity_mw`) and
coordinates to NRC units from EIA's monthly generator inventory (Form
EIA-860M). It never creates or renames units.

**EIA also proposes plants (#121)**, so the directory can grow when NRC's list
can't be read. Each EIA plant gives up to three candidates, quoting its first
generator row: its **site** (name, `eia_plant_id`, state, coordinates,
`power_reactor`, and `operating` for EIA's `(OP)` code), and, when the row names
an operator, its **operator** (EIA's entity name) and an **`operates`** link
between them. A plant with no entity name gives only its site. They go through match, verify and a human's
approval like any candidate. A site is found by `eia_plant_id` first, so a plant
is proposed once and found on every later run; then by name, so a seed site
with the same name gets EIA's row as more evidence. A look-alike ("Vogtle" and
"Plant Vogtle") goes to review. NRC's units aren't look-alikes of an EIA site:
they belong under it. NRC stays preferred for dockets, reactor types and
licensees, and a disagreement with a human-reviewed value goes to review.

**One site per plant (#73).** When a generator's values are published to its
NRC unit, a unit with no site yet goes under the site for its EIA plant ID,
unless that site was rejected or unpublished. A unit that already has a site
(a seed site such as Plant Vogtle) keeps it. A site that is still pending is
public only once one of its units is verified, so an EIA site nobody has
approved never shows up empty; a site a human approved is public like any
verified fact. Units enriched before #73 are grouped once with:

```bash
docker compose run --rm web bin/rails "data_quality:run[eia_generators]"
docker compose run --rm web bin/rails data_quality:group_units
```

- **Crawl** reads EIA's 860M page, takes the newest `<month>_generator<year>.xlsx`,
  and stores only its nuclear rows as CSV. There's one source per monthly
  file, so evidence names the exact file. If the workbook can't be read (for
  example, the layout changed), the source is marked `needs_human`.
- **Extract** makes a `facility` candidate per generator. The payload carries
  `"identify" => { "name", "state", "unit", "eia_plant_id" }` and the values to
  set. The quote is the generator's CSV row.
- **Match** finds the unit, in this order (`Directory::Lookup.facility_units`):
  1. the NRC units sharing the **most** distinctive words with EIA's plant name
     ("Wolf Creek" picks Wolf Creek 1 over Hope Creek 1);
  2. among those, units in EIA's state or with no state yet (a tie-break only;
     NRC unit candidates carry no state, and EIA's is used);
  3. the one with the same unit number. A plant with a single, unnumbered NRC
     unit takes that unit ("R E Ginna" → "Ginna").
  - The candidate is attached; nothing is written until verify publishes it.
  - Two equally good fits, or a rejected unit → `needs_review`.
  - No fit yet → the candidate stays `new` and is retried on the next run.
- **Verify** writes only the values. The unit's verification is unchanged,
  since EIA doesn't vouch for the record itself. A verified unit's
  coordinates also fill its site's blank ones.

Any payload with an `"identify"` key is treated as enrichment this way.
