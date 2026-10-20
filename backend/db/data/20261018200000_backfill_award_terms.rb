# Writes an award deal term (#256) for every DOE award row already stored on
# a funds link's USAspending sources, once, on the deploy after #264's table
# exists. Approved by Tosin with deal terms (#256, #264); merging this PR is
# the approval of the run. Directory::AwardBackfill says what each term is.
#
# Idempotent: an award a link already has (in any state) is left alone, so a
# rerun writes nothing. A term is verified only on a link a person verified;
# on a pending link it waits with the link. A row it can't write (its link
# closed meanwhile) is named in the output and left for the rake task's rerun.
class BackfillAwardTerms < DeployData::Migration
  BY = "human:tosin"

  def up
    result = Directory::AwardBackfill.new(by: BY, reason:).run(apply: true)
    say result.lines
    say result.summary(apply: true)
  end
end
