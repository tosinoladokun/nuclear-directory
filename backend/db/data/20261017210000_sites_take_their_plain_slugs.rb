# #333: four plants live at "-2" because their own NRC unit took the plain
# slug first. Each takes it back; the unit moves to "<slug>-unit", and the
# old addresses stay as former slugs, so they 301. Approved by Tosin through
# PM on 17 Oct. Hermes (hermes-2) is left alone: its plain slug isn't held by
# one of its own units.
class SitesTakeTheirPlainSlugs < DeployData::Migration
  BY = "human:tosin"
  # What the decision rests on: the plain slugs these sites should own.
  EXPECTED = %w[callaway davis-besse palisades waterford-3].freeze

  def up
    moved = Facility.give_sites_their_plain_slugs!
    unexpected = moved.map { |site, *| site.slug } - EXPECTED
    raise "#333: would also move #{unexpected.join(", ")}; check before running" if unexpected.any?
    # Every expected site must end at its plain slug (already there counts),
    # or nothing is kept and the next deploy tries again.
    missing = EXPECTED - Facility.where(parent_id: nil, slug: EXPECTED).pluck(:slug)
    raise "#333: #{missing.join(", ")} didn't take its plain slug; check before running" if missing.any?

    say "Nothing to move: every site already has its plain slug." if moved.empty?
    moved.each do |site, old, unit, unit_old|
      say "#{site.name}: /plants/#{old} -> /plants/#{site.slug} (unit #{unit.name}: #{unit_old} -> #{unit.slug})"
    end
  end
end
