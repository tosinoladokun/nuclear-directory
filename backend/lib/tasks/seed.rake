namespace :seed do
  desc "Dry run: list names, aliases and domains the seed would collide on in this database, " \
    "and licensing stages that aren't cited to an NRC record"
  task check: :environment do
    loader = Seed::OrganizationLoader.new(Rails.root.join("db/seeds/organizations"))
    problems = loader.collisions + loader.licensing_source_problems
    puts problems.any? ? problems : "No collisions: the seed's names, aliases and domains are free or already its own. " \
      "Every licensing stage is cited to an NRC record."
    exit 1 if problems.any?
  end
end
