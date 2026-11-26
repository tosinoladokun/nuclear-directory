require "net/http"

# The data repo on GitHub (#950), through the REST API only: no git binary
# and no files on disk. Reads work without a token (the repo is public);
# writes need DATASET_GITHUB_TOKEN, a fine-grained token limited to the data
# repo with Contents read and write.
#
# The token is never logged or put in an error: an Error says which call
# failed and GitHub's status and message, nothing else.
module Dataset
  class Github
    REPO = Export::DATA_REPO
    API = "https://api.github.com".freeze
    TIMEOUT = 30

    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        @status = status
        super(message)
      end
    end

    # timeout: seconds per call. A dry run from the admin page uses a short
    # one, so a slow GitHub can't hold a web thread for long (Infra).
    def initialize(token: ENV["DATASET_GITHUB_TOKEN"].presence, timeout: TIMEOUT)
      @token = token
      @timeout = timeout
    end

    def token? = @token.present?

    # The newest release's tag ("v2026.11"), or nil before the first.
    def latest_tag
      get("/releases/latest")&.fetch("tag_name")
    end

    # A file's text at a tag, or nil when it isn't there.
    def file(path, ref:)
      body = request(:get, "/contents/#{path}?ref=#{CGI.escape(ref)}", accept: "application/vnd.github.raw", raw: true)
      body&.force_encoding(Encoding::UTF_8)
    end

    # The commit a branch points at.
    def branch_sha(branch) = get("/git/ref/heads/#{branch}").dig("object", "sha")

    # The commit a tag points at (through its tag object when it's annotated),
    # or nil when there's no such tag.
    def tag_commit(tag)
      ref = get("/git/ref/tags/#{tag}") or return
      object = ref.fetch("object")
      object["type"] == "tag" ? get("/git/tags/#{object.fetch("sha")}").dig("object", "sha") : object.fetch("sha")
    end

    def commit(sha) = get("/git/commits/#{sha}")

    # How commit `head` stands against `base`: "ahead" (base is its
    # ancestor), "behind" (it's already in base), "identical" or "diverged".
    def compare(base, head) = get("/compare/#{base}...#{head}").fetch("status")

    # { path => blob sha } for every file in a tree.
    def tree_files(sha)
      tree = get("/git/trees/#{sha}?recursive=1")
      raise Error, "the data repo's tree is too big to read in one call" if tree["truncated"]

      tree.fetch("tree").select { |entry| entry["type"] == "blob" }.to_h { |entry| [ entry["path"], entry["sha"] ] }
    end

    def create_blob(content)
      post("/git/blobs", content: Base64.strict_encode64(content), encoding: "base64").fetch("sha")
    end

    def create_tree(base_tree:, entries:) = post("/git/trees", base_tree:, tree: entries).fetch("sha")

    def create_commit(message:, tree:, parent:) = post("/git/commits", message:, tree:, parents: [ parent ]).fetch("sha")

    # Moves a branch to a commit. Never forced, so it fails if the branch has
    # moved on since the commit's parent was read.
    def move_branch(branch, sha) = request(:patch, "/git/refs/heads/#{branch}", body: { sha:, force: false })

    # An annotated tag, like v2026.11's, and its ref.
    def create_tag(tag, sha:, message:)
      object = post("/git/tags", tag:, message:, object: sha, type: "commit").fetch("sha")
      post("/git/refs", ref: "refs/tags/#{tag}", sha: object)
    end

    def release(tag) = get("/releases/tags/#{tag}")

    def create_release(tag:, name:, body:) = post("/releases", tag_name: tag, name:, body:)

    private
      def get(path) = request(:get, path)
      def post(path, body) = request(:post, path, body:)

      # The parsed body, or nil on a 404 for a GET.
      def request(method, path, body: nil, accept: "application/vnd.github+json", raw: false)
        uri = URI("#{API}/repos/#{REPO}#{path}")
        request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
        request["Accept"] = accept
        request["X-GitHub-Api-Version"] = "2022-11-28"
        request["User-Agent"] = "nuclear-directory-dataset"
        request["Authorization"] = "Bearer #{@token}" if @token
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @timeout, read_timeout: @timeout, write_timeout: @timeout) do |http|
          http.request(request)
        end
        status = response.code.to_i
        return nil if status == 404 && method == :get
        unless status.between?(200, 299)
          message = (JSON.parse(response.body)["message"] rescue nil).to_s.first(200)
          raise Error.new("GitHub said #{status} to #{method.upcase} #{path.split('?').first}#{": #{message}" if message.present?}", status:)
        end
        raw ? response.body : JSON.parse(response.body.presence || "{}")
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "GitHub didn't answer #{method.upcase} #{path.split('?').first} (#{e.class.name.demodulize})"
      end
  end
end
