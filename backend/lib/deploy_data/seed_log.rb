module DeployData
  # The loader's per-kind counts, read from db:seed's output
  # ("organization  0 created,  68 updated"), for the report. Used until
  # db:seed writes tmp/seed_counts.json (Backend, #301), which then wins.
  module SeedLog
    LINE = /^(\w+)\s+(\d+) created,\s+(\d+) updated$/

    module_function

    def counts(log)
      log.to_s.lines.filter_map { |line| LINE.match(line.strip) }
        .to_h { |match| [ match[1], { "created" => match[2].to_i, "updated" => match[3].to_i } ] }
    end

    # Writes to both: the deploy log and the copy read back.
    class Tee
      def initialize(*outputs) = @outputs = outputs
      def write(*args) = @outputs.map { |output| output.write(*args) }.first
      def flush = @outputs.each(&:flush)
      def sync = true
      def sync=(_value); end
      def tty? = false
      def fileno = @outputs.first.fileno
    end
  end
end
