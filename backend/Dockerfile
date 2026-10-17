# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t nuclear_directory .
# docker run -d -p 80:3000 -e RAILS_MASTER_KEY=<value from config/master.key> --name nuclear_directory nuclear_directory

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.12
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages. The Postgres client is 16, from the PostgreSQL apt
# repo, to match the server: bin/deploy-data takes a backup with bin/backup
# before a data deploy (#301), and a dump from a newer pg_dump (Debian's is
# 17) can't be restored by the 16 tools in the backup image. age encrypts
# the backup, jq reads the GitHub API.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates curl && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    . /etc/os-release && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y age jq libjemalloc2 libvips postgresql-client-16 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# IP-to-country data for analytics (#205): DB-IP's "IP to Country Lite", CC BY
# 4.0, credited on /privacy. This month's file, or last month's early in a
# month; each deploy picks up the newest. Without it the build still succeeds
# and events carry no country (lib/geo_country.rb).
RUN mkdir -p vendor/geo && cd vendor/geo && \
    { curl -fsSL -o country.mmdb.gz "https://download.db-ip.com/free/dbip-country-lite-$(date -u +%Y-%m).mmdb.gz" || \
      curl -fsSL -o country.mmdb.gz "https://download.db-ip.com/free/dbip-country-lite-$(date -u -d "$(date -u +%Y-%m-01) -1 month" +%Y-%m).mmdb.gz"; } && \
    gunzip -c country.mmdb.gz > dbip-country-lite.mmdb && rm country.mmdb.gz || \
    { rm -f country.mmdb.gz dbip-country-lite.mmdb; echo "No IP-to-country data; analytics events will carry no country"; }

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
