# Nuclear Directory

[![CI](https://github.com/tosinoladokun/nuclear-directory/actions/workflows/ci.yml/badge.svg)](https://github.com/tosinoladokun/nuclear-directory/actions/workflows/ci.yml)

**An open directory of the US nuclear industry: who makes the fuel, builds the
reactors, runs the plants, buys the power and funds it.** Every fact on the
site links to its public source, and anything the AI pipeline finds waits for
a person to approve it before it's published. Live at
[nuclear-directory.org](https://nuclear-directory.org).

## Stack

- **App:** Rails 8.1 (Ruby 3.3) in `backend/`, with Hotwire and Tailwind, and
  a small design system (`nd-*` components, see [DESIGN.md](DESIGN.md)).
- **Database:** Postgres 16. Background jobs (Solid Queue), cache and cable
  live in the same database, so there's no Redis.
- **AI:** OpenRouter models extract and check facts from public sources
  (`backend/app/data_quality/`), within a monthly spend cap.
- **Hosting:** Render (one web service, Postgres, a daily backup job and a
  free preview service), described in [`render.yaml`](render.yaml). DNS at
  Namecheap, errors and uptime in Sentry, anonymous analytics in PostHog.
- **CI:** GitHub Actions: tests, RuboCop, a Lighthouse mobile check and a
  `render.yaml` check, all required before merging.

## How data flows

```
public sources ──crawl──▶ extract ──▶ match ──▶ verify ──▶ admin review ──▶ published
                (daily)    (AI)    (to records) (AI, a second   (a person      (public site,
                                                 model)        approves)       JSON snapshot)
```

1. **Seed data.** Hand-checked companies and plants in `backend/db/seeds/`,
   each fact with its source and quote, load with `bin/rails db:seed`.
2. **Daily crawl.** At 3 a.m. New York time, a job runs the pipeline for the
   NRC reactor list and EIA's generator data: crawl, extract facts with an AI
   model, match them to existing records, and verify each against its source
   with a second model.
3. **Review.** Verify only recommends. Every new or changed fact waits in the
   admin (`/admin`) until a person approves or rejects it, with the evidence
   alongside.
4. **Publish.** Only approved facts appear on the public pages, in search and
   in the [public JSON snapshot](docs/snapshot-api.md).

Details: [`backend/app/data_quality/README.md`](backend/app/data_quality/README.md)
(the pipeline) and [docs/DATA.md](docs/DATA.md) (the data standard).

## Repo layout

- `backend/`: the Rails app, its tests and the seed data
- `backup/`: the daily encrypted off-site backup job and restore tools
- `docs/`: public docs (below)
- `render.yaml`: production on Render; `docker-compose.yml`: local development
- [DESIGN.md](DESIGN.md) and [VOICE.md](VOICE.md): how the site looks and how
  it speaks; read them before changing a page or any visible text

## Docs

- [Public JSON snapshot](docs/snapshot-api.md)
- [Data standard](docs/DATA.md)

## Licence

The code is licensed under the [MIT License](LICENSE). Directory data and
dataset releases are licensed under [CC BY 4.0](DATA_LICENSE). Credit:
"Nuclear Directory, nuclear-directory.org".

Operational runbooks (deploying to Render, backups and restores, UI previews,
local Metabase, the analytics relay) live in the private
`nuclear-directory-backups` repo, next to the encrypted backups, for the
maintainers.

## Run it

You only need [Docker](https://www.docker.com/products/docker-desktop/).

```bash
cp .env.example .env
```

```bash
docker compose run --rm web bin/rails db:prepare
```

```bash
docker compose up
```

Then open http://localhost:3000. Stop with `Ctrl+C`; add `-d` to `up` to run it
in the background and `docker compose down` to stop it.

`db:prepare` creates the database, runs migrations and, on first setup, loads
the seed data. Rerun it after pulling new migrations.

The seed data is the roles and technologies lists plus 68 hand-checked
organizations, one YAML file each in `backend/db/seeds/organizations/`, and
plant details in `backend/db/seeds/facilities.yml`. Every fact in them is
loaded with its source and quote as evidence, and is verified (public) unless
its file marks it `pending: true`. Three plant links are pending because their
quote doesn't state ownership directly; they stay off the site until a human approves them
(the admin review queue will list pending facts, #92).
After changing `backend/db/seeds.rb` or those files, reload the seeds (safe to
re-run):

```bash
docker compose run --rm web bin/rails db:seed
```

## Run the tests

```bash
docker compose run --rm web bin/rails db:test:prepare test
```

CI runs the same tests plus RuboCop (the style checker) on every pull
request and on `main`. Run the linter locally with:

```bash
docker compose run --rm web bin/rubocop
```

Tests use a separate `nuclear_directory_test` database, so they never touch
development data.

## Open a console

Rails console:

```bash
docker compose run --rm web bin/rails console
```

Postgres shell:

```bash
docker compose exec db psql -U postgres nuclear_directory_development
```

## Configuration

Settings live in `.env` (gitignored). See `.env.example` for the full list:
`DATABASE_URL`, `OPENROUTER_API_KEY` and the OpenRouter model ids. Never
commit real keys.

`backend/config/master.key` decrypts `backend/config/credentials.yml.enc`. It
is gitignored; keep a copy in a password manager.

## Starting over

To wipe the database and installed gems:

```bash
docker compose down -v
```
