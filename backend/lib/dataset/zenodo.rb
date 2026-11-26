require "net/http"

# Zenodo's side of a dataset release (#950). Zenodo archives each GitHub
# release of the data repo by itself and mints a version DOI under the
# concept DOI. This reads Zenodo's public records API (no token) to find
# that version's DOI, then checks the DOI resolves at doi.org.
#
#   Dataset::Zenodo.new.version_doi("2026.12") # => "10.5281/zenodo.…" or nil
module Dataset
  class Zenodo
    CONCEPT_DOI = StructuredDataHelper::DATASET_DOI
    CONCEPT_ID = CONCEPT_DOI.split(".").last
    RECORDS = "https://zenodo.org/api/records".freeze
    TIMEOUT = 15

    class Error < StandardError; end

    # The version's DOI once Zenodo has it and doi.org resolves it; nil
    # until then. Zenodo names a version as the release does ("2026.11");
    # the tag ("v2026.11") is accepted too.
    def version_doi(version)
      hit = versions.find { |record| [ version, "v#{version}" ].include?(record.dig("metadata", "version").to_s) }
      doi = hit && hit["doi"].presence
      doi if doi && resolves?(doi)
    end

    private
      # The newest versions under the concept DOI, newest first.
      def versions
        uri = URI("#{RECORDS}?q=#{CGI.escape("conceptrecid:#{CONCEPT_ID}")}&all_versions=true&sort=mostrecent&size=25")
        response = get(uri, accept: "application/json")
        raise Error, "Zenodo said #{response.code} to the records search" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body).dig("hits", "hits") || []
      rescue JSON::ParserError
        raise Error, "Zenodo's records search didn't return JSON"
      end

      # doi.org answers a registered DOI with a redirect to the record.
      def resolves?(doi)
        get(URI("https://doi.org/#{doi}"), method: Net::HTTP::Head).is_a?(Net::HTTPRedirection)
      end

      def get(uri, accept: nil, method: Net::HTTP::Get)
        request = method.new(uri)
        request["Accept"] = accept if accept
        request["User-Agent"] = "nuclear-directory-dataset"
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.request(request) }
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "#{uri.host} didn't answer (#{e.class.name.demodulize})"
      end
  end
end
