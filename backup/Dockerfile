# Daily off-site database backup (issue #54), run by the Render cron job in
# render.yaml. Postgres 16 tools to match the server and the restore, plus
# age to encrypt and curl/jq to talk to the GitHub API.
FROM docker.io/library/postgres:16-bookworm

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y age ca-certificates curl jq && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Built from the repo root: the backup script is shared with the app image,
# which runs it before a data deploy (#301, bin/deploy-data).
COPY backend/bin/backup /usr/local/bin/backup
COPY backup/restore.sh /usr/local/bin/restore
COPY backend/lib/backup/*.jq /usr/local/share/backup/

USER postgres
ENTRYPOINT []
CMD ["backup"]
