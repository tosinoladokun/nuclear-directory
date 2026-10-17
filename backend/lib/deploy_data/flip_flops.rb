module DeployData
  # A seed that ran before should write no verification events for records
  # whose files didn't change. Events it does write for them are flip-flops
  # (two files fighting over one value, as with the Vogtle shares fixed in
  # #299), listed in the report for Data Quality.
  #
  # A record belongs to the organization files it comes from: an
  # organization's own file (db/seeds/organizations/<slug>.yml), both sides'
  # files for a relationship, and for a plant every owner's file plus
  # db/seeds/facilities.yml.
  module FlipFlops
    FACILITIES_FILE = "db/seeds/facilities.yml".freeze

    module_function

    # events: VerificationEvents the seed wrote. changed: paths changed since
    # the last applied run. Returns one line per event's record, e.g.
    # "Organization 12 (kairos-power): 2 events".
    def find(events, changed:)
      changed_slugs = changed.filter_map { |path| path[%r{\Adb/seeds/organizations/(.+)\.yml\z}, 1] }.to_set
      facilities_changed = changed.include?(FACILITIES_FILE)

      events.group_by { |event| [ event.subject_type, event.subject_id ] }.filter_map do |(type, id), group|
        slugs, facility = owners(type, id)
        next if slugs.intersect?(changed_slugs) || (facility && facilities_changed)

        "#{type} #{id} (#{slugs.to_a.sort.join(', ').presence || 'no seed file'}): #{group.size} #{'event'.pluralize(group.size)}"
      end
    end

    # [organization slugs, whether it's plant data]
    def owners(type, id)
      case type
      when "Organization" then [ Organization.where(id:).pluck(:slug).to_set, false ]
      when "OrganizationRole", "OrganizationTechnology"
        [ Organization.where(id: type.constantize.where(id:).select(:organization_id)).pluck(:slug).to_set, false ]
      when "Relationship"
        relationship = Relationship.find_by(id:)
        [ Organization.where(id: [ relationship&.from_organization_id, relationship&.to_organization_id ]).pluck(:slug).to_set, false ]
      when "FacilityRelationship"
        [ Organization.where(id: FacilityRelationship.where(id:).select(:organization_id)).pluck(:slug).to_set, true ]
      when "Facility"
        facility = Facility.find_by(id:)
        ids = [ id, facility&.parent_id ].compact
        [ Organization.where(id: FacilityRelationship.where(facility_id: ids).select(:organization_id)).pluck(:slug).to_set, true ]
      else [ Set.new, false ]
      end
    end
  end
end
