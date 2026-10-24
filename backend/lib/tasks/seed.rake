namespace :seed do
  desc "Dry run: list names, aliases and domains the seed would collide on in this database, " \
    "and licensing stages that aren't cited to an NRC record"
  task check: :environment do
    loader = Seed::OrganizationLoader.new(Rails.root.join("db/seeds/organizations"))
    problems = loader.collisions + loader.licensing_source_problems
    puts problems.any? ? problems : "No collisions: the seed's names, aliases and domains are free or already its own. " \
      "Every licensing stage is cited to an NRC record."
    # Shown values no record quote states (#407): drift to fix, not a collision.
    %w[unquoted-docket-place unquoted-hq unquoted-legal-name].each do |key|
      tag = Directory::Checks.find(key)
      count = tag.queries.sum { |_model, query| query.call.count }
      puts "#{tag.label}: #{count} (#{tag.hint.downcase_first}; listed in Live)" if count.positive?
    end
    exit 1 if problems.any?
  end
end
