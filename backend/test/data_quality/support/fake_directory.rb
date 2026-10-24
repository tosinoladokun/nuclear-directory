# In-memory stand-ins for Directory::Lookup and Directory::FactWriter, so
# the module's own tests don't depend on directory data. They have the same
# method signatures and return the real value classes (OrganizationRef,
# FacilityRef, FactWriter::Result), and directory_client_test.rb checks the
# signatures still match, so the fakes can't drift from the real thing.
module FakeDirectory
  class Lookup
    def initialize(organizations: {}, facilities: {})
      @organizations = organizations # name => id
      @facilities = facilities
    end

    def cik(value)
      text = value.to_s.strip.presence or return
      digits = text.sub(/\ACIK/i, "")
      digits.match?(/\A\d{1,10}\z/) ? digits.rjust(10, "0") : text
    end

    def organization(id: nil, slug: nil, name: nil, domain: nil, sec_cik: nil)
      one_of!(id:, slug:, name:, domain:, sec_cik:)
      Directory::OrganizationRef.new(id: @organizations[name], slug: nil, name: name, domain: nil, sec_cik: nil,
        verification_status: "verified", verified_by: nil, verified_at: nil) if @organizations.key?(name)
    end

    # No company in the fake has a CIK.
    def organizations_with_sec_cik = []

    def facility(id: nil, slug: nil, name: nil, site_name: nil, nrc_docket: nil, eia_plant_id: nil)
      one_of!(id:, slug:, name:, site_name:, nrc_docket:, eia_plant_id:)
      Directory::FacilityRef.new(id: @facilities[name], slug: nil, name: name, nrc_docket: nil, eia_plant_id: nil, parent_id: nil,
        verification_status: "verified", verified_by: nil, verified_at: nil, facility_type: nil, status: nil, state: nil, country_code: nil,
        latitude: nil, longitude: nil) if @facilities.key?(name)
    end

    # The fake knows nothing similar; match tests that need it use the real directory.
    def similar_organizations(name) = []
    def same_brand_organizations(name, plants: nil) = []
    def brand_name(name, plants: nil) = nil
    def brand_key(name, plants: nil) = nil
    def plant_names(owners: []) = Set.new

    def fact_state(type:, id:) = nil
    def fact_attributes(type:, id:) = nil
    def published?(type:, id:) = false
    def sourced?(type:, id:) = true
    def evidence(type:, id:) = []
    def open_corrections?(type:, id:) = false
    def similar_facilities(name) = []
    def facility_units(name:, state: nil) = []

    private
      # Same rule as the real Lookup.
      def one_of!(**options)
        raise ArgumentError, "pass exactly one of #{options.keys.join(", ")}" unless options.compact.size == 1
      end
  end

  class FactWriter
    attr_reader :writes

    def initialize(fail_with: nil)
      @fail_with = fail_with
      @writes = []
      @next_id = 1000
    end

    # Nothing here is ever merged.
    def repoint_merged_claims = 0

    def write(kind, attributes, evidence: [], verification: nil, fill_blank: false, protect_human_verified: false,
      remove_aliases: [], create_only: false)
      @writes << { kind:, attributes:, evidence:, verification:, fill_blank: }
      return Directory::FactWriter::Result.new(kind: kind.to_sym, id: nil, created: false, errors: [ @fail_with ]) if @fail_with

      id = attributes[:id] || (@next_id += 1)
      Directory::FactWriter::Result.new(kind: kind.to_sym, id: id, created: !attributes[:id], errors: [])
    end

    # The fake directory has no closed facts.
    def while_open(type:, id:)
      yield
      nil
    end

    def remove_evidence(type:, id:, evidence_id:, source_id:, quote:, by:, reason:)
      @writes << { remove_evidence: evidence_id, type:, id:, source_id:, quote:, by:, reason: }
      kind = type.to_s.underscore.to_sym
      return Directory::FactWriter::Result.new(kind:, id: nil, created: false, errors: [ @fail_with ]) if @fail_with

      Directory::FactWriter::Result.new(kind:, id:, created: false, errors: [])
    end

    # The fake directory has no sites to fill.
    def fill_site_from_unit(unit_id, fields:, evidence:) = nil

    # The fake directory keeps no evidence, so nothing is ever re-confirmed.
    def confirm(kind, attributes, source_id:, quote:, in_source: nil, rows_sha256: nil, at: Time.current)
      Directory::FactWriter::Confirmation.new(outcome: :unsourced)
    end

    def reconfirm_source(source_id:, facts:, quotes:, rows_sha256:, at: Time.current) = 0
    def existing(kind, attributes) = nil
  end

  def self.client(lookup: Lookup.new, fact_writer: FactWriter.new)
    DataQuality::DirectoryClient.new(lookup: lookup, fact_writer: fact_writer)
  end
end
