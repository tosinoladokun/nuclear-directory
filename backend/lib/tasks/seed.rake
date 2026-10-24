namespace :seed do
  desc "Dry run: list names, aliases and domains the seed would collide on in this database"
  task check: :environment do
    collisions = Seed::OrganizationLoader.new(Rails.root.join("db/seeds/organizations")).collisions
    puts collisions.any? ? collisions : "No collisions: the seed's names, aliases and domains are free or already its own."
    # Shown values no record quote states (#407): drift to fix, not a collision.
    %w[unquoted-docket-place unquoted-hq unquoted-legal-name].each do |key|
      tag = Directory::Checks.find(key)
      count = tag.queries.sum { |_model, query| query.call.count }
      puts "#{tag.label}: #{count} (#{tag.hint.downcase_first}; listed in Live)" if count.positive?
    end
    exit 1 if collisions.any?
  end
end
