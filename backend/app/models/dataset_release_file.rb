# One file of a dataset release (#950), gzipped, with its size and its git
# blob id, so a dry run can say which files differ from the data repo
# without uploading anything.
class DatasetReleaseFile < ApplicationRecord
  belongs_to :release, class_name: "DatasetRelease", foreign_key: :dataset_release_id, inverse_of: :files

  def self.git_sha(content) = Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")

  def self.build_from(path, content)
    content = content.b
    new(path:, content_gz: ActiveSupport::Gzip.compress(content), bytes: content.bytesize, git_sha: git_sha(content))
  end

  def content = ActiveSupport::Gzip.decompress(content_gz)
end
