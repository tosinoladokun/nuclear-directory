require "net/http"
require "json"

module DeployData
  # Posts the data step's report on GitHub: as a comment on the PR the
  # deploy's commit came from, or as a new issue when there's none (a direct
  # push). Uses DEPLOY_REPORT_GITHUB_TOKEN, a fine-grained token for this
  # repo with Issues and Pull requests write only. Never raises: a report
  # that can't be posted is still in the deploy log and Sentry.
  class GitHub
    REPO = "tosinoladokun/nuclear-directory".freeze

    def initialize(token: ENV["DEPLOY_REPORT_GITHUB_TOKEN"].presence, repo: ENV["DEPLOY_REPORT_REPO"].presence || REPO)
      @token = token
      @repo = repo
    end

    def configured? = !@token.nil?

    # The number of the merged PR the commit came from, or nil.
    def pull_request_for(commit)
      return unless configured? && commit.present?

      pulls = request(:get, "/repos/#{@repo}/commits/#{commit}/pulls")
      Array(pulls).find { |pull| pull["merged_at"] }&.dig("number") || Array(pulls).first&.dig("number")
    rescue StandardError => error
      warn "deploy-data: couldn't look up the PR for #{commit}: #{error.message}"
      nil
    end

    # Returns the comment's or issue's URL, or nil.
    def post(body, pull_request:, title:)
      return unless configured?

      result = if pull_request
        request(:post, "/repos/#{@repo}/issues/#{pull_request}/comments", body:)
      else
        request(:post, "/repos/#{@repo}/issues", title:, body:)
      end
      result["html_url"]
    rescue StandardError, Run::TimedOut => error
      # The data step is over by now (its outcome already decided), so a
      # timeout here is only a report that didn't arrive: Run alerts Sentry.
      warn "deploy-data: couldn't post the report to GitHub: #{error.message}"
      nil
    end

    private
      def request(verb, path, **payload)
        uri = URI("https://api.github.com#{path}")
        request = (verb == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = "2022-11-28"
        request.body = payload.to_json unless payload.empty?
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(request) }
        raise "GitHub #{verb.upcase} #{path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
  end
end
