# Directory interfaces

`Directory::Lookup` (read) and `Directory::FactWriter` (write) are the **only**
way code outside the directory touches directory data. The data quality
pipeline (`DataQuality::`) and the seed loader both go through them, so there
is one way facts get written. Decision and reasoning: issue #1 (comments),
issue #32.

## Who owns what

| Directory owns | DataQuality owns |
|---|---|
| organizations, organization_aliases, facility_aliases, roles, technologies, organization_roles, organization_technologies, facilities, relationships, facility_relationships, evidence | sources, crawl_runs, candidates |

`evidence.source_id` is the one foreign key that crosses the line. Outside the
directory, don't use the directory's models (`Organization`, `Facility`, …)
directly. Call these interfaces instead.

## Directory::Lookup

Returns frozen value objects (`Directory::OrganizationRef`,
`Directory::FacilityRef`), never models, or `nil` when nothing matches. Pass
exactly one keyword.

```ruby
Directory::Lookup.organization(name: "TerraPower, Inc.")   # name or any alias, normalized
Directory::Lookup.organization(domain: "https://www.terrapower.com/news")
Directory::Lookup.organization(slug: "terrapower")
Directory::Lookup.organization(id: 12)

Directory::Lookup.facility(nrc_docket: "05000424")
Directory::Lookup.facility(eia_plant_id: "649")  # the site for that EIA plant
Directory::Lookup.facility(site_name: "Palisades")  # a site (no docket) by name or alias, never a unit
Directory::Lookup.facility(name: "Plant Vogtle")  # case-insensitive
Directory::Lookup.facility(name: "Three Mile Island Unit 1")  # or any alias: Crane Clean Energy Center
```

- `OrganizationRef`: `id, slug, name, domain, verification_status, verified_by, verified_at`
- `FacilityRef`: `id, slug, name, nrc_docket, parent_id, verification_status, verified_by, verified_at, facility_type, status, state, country_code, latitude, longitude`
- `Directory::Lookup.ids_by_slug(type:, slugs:)`: company (`Organization`) or plant (`Facility`) ids by slug, in one query
- `Directory::Lookup.published?(type:, id:)`: whether a fact is public now, by its model's `.published` scope
- `Directory::Lookup.sourced?(type:, id:)`: whether a fact has any evidence
- `Directory::Lookup.fact_attributes(type:, id:)`: any fact's stored values as FactWriter names them (string keys, link ends as ids plus the linked records' names), or nil
- `Directory::Lookup.fact_state(type:, id:)`: any fact's current decision, as `FactStateRef(type, id, name, verification_status, verified_by, verified_at)` (a link's name is a short label)

Every verification status is returned, so check `verification_status` before
treating a match as public.

```ruby
Directory::Lookup.similar_facilities("Vogtle 3")                       # => [FacilityRef, …] (up to 10)
Directory::Lookup.similar_organizations("Southern Nuclear Operating Co.")
```

These find likely duplicates that an exact lookup misses: records that share
the same leading distinctive word, ignoring unit numbers and generic words
like "nuclear", "station" or "company". Used to send a candidate to review
instead of creating a duplicate.

Names are compared after `OrganizationAlias.normalize`: lowercased, `&` becomes
"and", punctuation removed, trailing Inc / LLC / Co / Corp / Ltd and similar
dropped. "TerraPower, LLC" and "terrapower" match.

## Directory::FactWriter

```ruby
result = Directory::FactWriter.write(kind, attributes, evidence: [...], verification: {...})
result.ok?      # true when written
result.id       # the fact's id
result.created  # true if new, false if an existing fact was updated
result.errors   # array of messages; empty when ok
```

A failed write changes nothing and returns errors. It does not raise.

### Kinds

| kind | attributes | an existing fact is found by |
|---|---|---|
| `organization` | `name slug legal_name website domain description hq_city hq_state country_code founded_year status aliases` | name or any alias (normalized), then domain |
| `organization_role` | `organization_id role` (role **key**) | organization + role |
| `organization_technology` | `organization_id technology` (technology **key**) | organization + technology |
| `facility` | `name slug parent_id facility_type status technology reactor_type capacity_mw nrc_docket eia_plant_id city state country_code latitude longitude aliases` | NRC docket, then EIA plant ID (sites only), then name or any alias (a site's name or alias for an EIA site) |
| `relationship` | `from_organization_id to_organization_id relationship_type description started_on ended_on` | from + to + type |
| `facility_relationship` | `organization_id facility_id relationship_type ownership_pct description started_on ended_on` | organization + facility + type |
| `deal_term` | `link_type link_id term_type external_id amount_usd capacity_mw signed_on starts_on ends_on status program round lead_investor_ids` | link + term type + `external_id` (no `external_id`: always a new row) |

Pass `id:` to update a fact you already know. Get ids for other records from
`Directory::Lookup`.

- **Facilities**: `aliases:` are other names the plant goes by ("Three Mile
  Island Unit 1", "TMI-1"), compared after `FacilityAlias.normalize`
  (lowercased, punctuation dropped, no words dropped). Lookups and search
  should find a plant under them. Its own name isn't stored as an alias, since
  facility names aren't unique. An alias another facility has, or that is
  another facility's name, is an error.
- **Organizations**: the name is stored as an alias as well, along with
  `aliases:`. An alias already used by another organization is an error.
  `remove_aliases:` (a keyword, with a human's `verification:`) drops
  aliases, never the current name, e.g. a former name that has no quote.
  `domain` defaults to the website's; pass `domain: nil` to leave it blank,
  for example when several organizations share one website.
- **Relationship types**: `supplies`, `invests_in` (equity), `funds` (grants
  and awards), `offtake_with`, `subsidiary_of` (child → parent).
- **Facility link types**: `owns`, `operates`, `vendor_for`, `offtakes_from`.

### Filling blanks

`fill_blank: true` sets only the attributes that are blank on an existing
row and leaves the rest alone, e.g. to complete a site's state and status
from one of its units without overwriting what's already there.

### Evidence

Each item: `source_id` (required), `quote`, `found_by` (`crawler`, `verifier`
or `human`), `confidence` (0–1), `crawl_run_id`. Evidence is matched by source
and quote, so writing the same item again updates it and never duplicates it.

Evidence attached to the wrong fact (#226) is removed by a human, never by the pipeline:

```ruby
Directory::FactWriter.remove_evidence(type: "FacilityRelationship", id: 112, evidence_id: 1114,
  source_id: 9, quote: "649,Vogtle,1,GA,…", by: "human:tosin",
  reason: "Quote is about Vogtle, not Nine Mile Point 1 (#226)")
```

`source_id` and `quote` must match the row, so a wrong id can't remove the right evidence. The fact is locked first. A rejected or unpublished fact isn't changed, and a
published or verified fact keeps at least one piece of evidence. The fact's audit trail
gets an event with the reason and `changed_values: { "evidence" => ["<source url>: <quote>", nil] }`.

### Re-confirming a fact (#240)

A person decides a fact once. When a crawl reads the same thing again, the pipeline asks
whether the source still says what the fact records instead of queueing it for review:

```ruby
Directory::FactWriter.confirm(:facility, { id: 12, name: "Hope Creek 1", status: "operating" },
  source_id: 9, rows_sha256: "…", at: source.fetched_at)
# => Confirmation(outcome: :confirmed | :different | :unsourced | :missing, differences:, overruled:, errors:)
```

- Values are compared as the model stores them: normalized, and a decimal at its column's
  scale. A value the source doesn't state isn't a difference. Names aren't compared, the
  same as in verify: spelling variants are expected, and which fact it is was already
  settled by its docket, plant ID, domain or an alias (or, for a link, by its ends).
- A value a human replaced (the "before" of a human event) is reported in `overruled`, not
  in `differences`. The person's decision stands. This means the value stays quiet until the
  source says something else. If a source returns to the old value for a real reason, it
  won't come back to review on its own.
- A link is the same claim only between its own ends. The caller passes the ends it found
  (`organization_id`, `facility_id`…), and a unit stands for its site's link. A claim
  attached to another link (#226) is a difference, never a confirmation.
- Only evidence whose quote the source still contains is stamped. With `in_source:` (the
  plug-in's check), every stamped quote must pass it, this claim's included. Without it, only
  the claim's own `quote` counts. If there's none, the outcome is `:unsourced`, and approving
  adds the current quote.
- The fact's decision doesn't matter. A rejected or unpublished fact confirmed this way
  stays as it is.
- When it's confirmed, the evidence from `source_id` gets `last_confirmed_at` and
  `confirmed_sha256`. Nothing else is written, and nothing goes to the audit trail, so a
  fact's history doesn't fill up with nightly checks. `:unsourced` means the fact has no
  evidence from this source yet.

`FactWriter.reconfirm_source(source_id:, facts:, quotes:, rows_sha256:, at:)` runs when a
source's rows haven't changed. It stamps only the evidence those rows still support: on the
listed facts (type and id pairs), and with one of the listed quotes. A fact the rows dropped
or contradict isn't stamped. `FactWriter.existing(kind, attributes)` returns the
id of the fact the attributes name (a link by its ends and type), or nil. It only reads.

### Verification

`verification: { status: "verified", by: "human:tosin", reason: "…", context: { … } }`.
Status is `pending`, `verified`, `rejected` or `unpublished`. `by` (required)
names who decided: `human:<name>` or `agent:verifier/<model>`. `reason` and `context`
(e.g. `{ "candidate_id" => 12, "crawl_run_id" => 4 }`) are optional and go
into the audit trail. Re-applying the same decision keeps the original
`verified_at` and records nothing new, unless it's a human's and the same
write changes values (an edit) or names a `context` (e.g. approving another
candidate for the fact): then it's recorded, so the history shows it. What's
public is what the
`.published` scopes return (below).

- **Unpublished** is a human taking a fact off the site (who and when are in
  `verified_by` / `verified_at`). Like `rejected`, it's a closed decision:
  automated writers (`protect_human_verified: true`) can't change the fact at
  all, and match sends a candidate citing it to review ("…which was
  unpublished by human:tosin on 2026-10-10"). A human republishes by writing
  `status: "verified"` again.
- **Only a human** (`by: "human:…"`) can unpublish, or change a fact that's
  rejected or unpublished. Any other write fails with an error. The pipeline
  may still reject, to retire its own proposals.
- **Human actions** (approve, unpublish, republish) are written *without*
  `protect_human_verified`: the human is the authority.

### What's public

Public pages read `<Model>.published`, not `.verified`: a fact is published
when it's verified **and** what it hangs on is published. Unpublishing a
company hides its roles, technologies, relationships and plant links;
unpublishing a site hides its units and their links. Nothing is deleted, and
each fact keeps its own decision, so republishing brings them all back.

One exception for sites (#73): a **pending** site is published once it has a
published unit (a verified unit under a site that isn't rejected or
unpublished), so a site made from NRC units goes public with its first
verified unit. A rejected or unpublished site never shows, whatever its units.

### Bulk writes

`Directory::FactWriter.write_many([{ kind:, attributes:, evidence:, verification:, protect_human_verified: }, …])`
runs a batch (e.g. a bulk approve) in one transaction, each write in its own
savepoint, so one failure doesn't undo the rest. It returns one Result per
write, in order. Each write is audited as usual.

### Audit trail

Every change of a fact's verification is recorded in `verification_events`
(who, when, from → to, reason, context, and the attribute values the same
write changed, before → after), append-only: events can't be edited or
deleted, and they outlive their fact. A human editing values without changing
the decision is recorded too. Decisions on one fact are made one at a time
(the row is locked), so the history is in the order they happened. Read it
with:

```ruby
Directory::Lookup.verification_history(type: "Organization", id: 12)
# => [VerificationEventRef(from_status:, to_status:, by:, reason:, context:, changed_values:, at:), …] newest first
# changed_values: { "hq_state" => ["DE", "WA"] }
```

### Deal terms (#256)

One award, offtake or funding round under the link it belongs to: "U.S.
Department of Energy funds X-energy" is a `Relationship`; each DOE award to
X-energy is a `DealTerm` with its own amount, dates, award ID and evidence.
`link_type` is `Relationship` or `FacilityRelationship`; `term_type` is
`award` (needs `amount_usd`, `starts_on`, `external_id`), `offtake` (needs
`capacity_mw` or `amount_usd`) or `funding_round` (needs `amount_usd` or
`round`). A term is a fact like any other: verified by a human, written with
evidence, and never moved off a closed link. A changed value on a
human-verified term comes back as a conflict. It's public only when it's
verified and its link is published.

```ruby
Directory::FactWriter.write(:deal_term, { link_type: "Relationship", link_id: 7, term_type: "award",
  external_id: "ASST_NON_DENE0009040_8900", amount_usd: "80000000.00", starts_on: "2020-10-13", program: "81.121" },
  evidence: [ { source_id: 9, quote: "<the USAspending row>", found_by: "crawler" } ])
Directory::Lookup.deal_terms(link_type: "Relationship", link_id: 7)
# => [DealTermRef(term_type:, external_id:, amount_usd:, starts_on:, ends_on:, program:, source_urls:, …), …] oldest first
```

Awards #260 stored before deal terms existed are written once with
`BY=human:<name> [APPLY=1] bin/rails directory:backfill_award_terms` (a dry
run without `APPLY`; safe to rerun).

### Pending facts (the review queue)

Facts waiting for a human's decision (`pending`; never rejected or
unpublished), one kind per call, oldest first:

```ruby
Directory::Lookup.pending_facts(kind: "facility_relationship", after_id: nil, limit: 50)
# => [PendingFactRef(type:, id:, kind:, attributes:, evidence:, created_at:, last_event:), …]
```

- `kind`: one of `Directory::Lookup::FACT_KINDS`. Page with `after_id:` (the
  last id seen).
- `attributes`: the FactWriter attributes as stored (roles and technologies
  as keys), plus the linked records' names (`organization_name`,
  `facility_name`, `from_organization_name`, `to_organization_name`,
  `parent_name`).
- `evidence`: `EvidenceRef(source_id:, quote:, found_by:, confidence:, crawl_run_id:)`.
  Only the source's id: sources belong to the data quality module, which
  resolves URLs and titles.
- `last_event`: the latest `VerificationEventRef`, e.g. why it's waiting.

Candidates aren't consulted: the data quality module leaves out facts an
open candidate already points at. To decide, write the fact as a human:
`FactWriter.write(kind, { id:, … }, verification: { status: "verified", by: "human:tosin", reason:, context: })`.

### Confidence

Recomputed after every write, by one rule in `Evidence.combined_confidence`:
a fact a human has verified scores 1. Otherwise it scores the strongest piece
of evidence, plus 0.1 when sources on two or more domains agree, capped at 1.
