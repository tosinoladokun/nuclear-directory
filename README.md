# nuclear-directory

[![CI](https://github.com/tosinoladokun/nuclear-directory/actions/workflows/ci.yml/badge.svg)](https://github.com/tosinoladokun/nuclear-directory/actions/workflows/ci.yml)

Open directory and relationship map of the US nuclear industry supply chain.

## Layout

- `backend/` — Rails 8 app (Ruby 3.3, Postgres 16, Hotwire, Tailwind)
- `docker-compose.yml` — local development: `db` (Postgres) and `web` (Rails)

Background jobs use Solid Queue, which stores jobs in Postgres (no Redis).
In development the job worker runs inside the web process.

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

The seed data is the roles and technologies lists plus 45 hand-checked
organizations, one YAML file each in `backend/db/seeds/organizations/`. Every
fact in them is loaded as verified, with its source and quote as evidence.
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

## Usage counts

The site keeps anonymous daily counts of page views per path and searches
per query, in the `usage_counts` table. It stores no cookies, IP addresses or
user agents and uses no third-party trackers. Bots, Turbo prefetches and the
`/design` page aren't counted. To see top pages, top searches and searches
with no results for the last 30 days:

```bash
docker compose run --rm web bin/rails "usage:report[30]"
```

A search page records each search with
`UsageCount.track_search(query, results: count)`.

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
