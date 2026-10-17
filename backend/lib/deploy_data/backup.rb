require "open3"

module DeployData
  # Takes a fresh encrypted backup before any write, with the same script as
  # the daily cron job (bin/backup), tagged backup-<time>-predeploy.
  module Backup
    class Failed < StandardError; end

    PG_BIN = "/usr/lib/postgresql/16/bin".freeze

    module_function

    # Returns the backup's tag; raises Failed if it didn't upload.
    def take!
      env = { "BACKUP_TAG_SUFFIX" => "predeploy", "BACKUP_JQ_DIR" => Rails.root.join("lib/backup").to_s }
      # The image's Postgres 16 tools, whatever else is on the PATH.
      env["PATH"] = "#{PG_BIN}:#{ENV['PATH']}" if File.directory?(PG_BIN)
      output, status = Open3.capture2e(env, Rails.root.join("bin/backup").to_s)
      puts output.lines.map { |line| "  #{line}" }.join
      tag = output[/^Uploaded to \S+ release (\S+)$/, 1]
      raise Failed, "the backup didn't finish (exit #{status.exitstatus})" unless tag

      # Published: the backup is safe even if pruning old ones failed after it.
      warn "deploy-data: the backup is published, but bin/backup exited #{status.exitstatus} after it (pruning)" unless status.success?
      tag
    end
  end
end
