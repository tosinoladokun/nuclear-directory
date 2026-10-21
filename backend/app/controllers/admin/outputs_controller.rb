# Where it appears (#166): what the public sees of the directory, and
# where: its pages (as the sitemap lists them), the link previews drawn
# for them, the snapshot API other sites read, and the open dataset to come.
# Read only.
class Admin::OutputsController < Admin::BaseController
  def show
    @pages = PublicPages.new
    @snapshot_updated_at = DirectorySnapshot.updated_at
  end
end
