require "test_helper"
require "open3"
require "tmpdir"

# bin/preview-start.sh wipes whatever database DATABASE_URL names, so it must
# only ever run against the preview database. A stub od that fails at once
# (the build name, next line after the guard) stops the script there, so
# nothing here touches a database.
class PreviewStartGuardTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/preview-start.sh").to_s
  REFUSED = "refusing to reset it"

  def run_script(url)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "od"), "#!/bin/sh\nexit 7\n")
      File.chmod(0o755, File.join(dir, "od"))
      env = { "DATABASE_URL" => url, "PATH" => "#{dir}:#{ENV.fetch("PATH")}" }
      _out, err, status = Open3.capture3(env, "bash", SCRIPT)
      [ err, status ]
    end
  end

  test "lets the preview database through, with or without Render's suffix" do
    [
      "postgresql://preview_app:x@dpg-a/nuclear_directory_preview",
      "postgresql://preview_app:x@dpg-a/nuclear_directory_preview?sslmode=require",
      "postgresql://preview_app:x@dpg-a/nuclear_directory_preview_uf9q",
      "postgresql://preview_app:x@dpg-a/nuclear_directory_preview_uf9q?sslmode=require"
    ].each do |url|
      err, status = run_script(url)
      assert_not_includes err, REFUSED, url
      assert_not status.success?, "the stub od should have stopped #{url}"
    end
  end

  test "refuses any other database, production's included" do
    [
      nil,
      "",
      "postgresql://app:x@dpg-b/nuclear_directory",
      "postgresql://app:x@dpg-b/nuclear_directory_x1y2",
      "postgresql://app:x@dpg-b/nuclear_directory_preview_old/extra",
      "postgresql://app:x@dpg-b/nuclear_directory_preview-copy",
      "postgresql://app:x@dpg-b/nuclear_directory?db=nuclear_directory_preview"
    ].each do |url|
      err, status = run_script(url.to_s)
      assert_includes err, REFUSED, url.inspect
      assert_equal 1, status.exitstatus, url.inspect
    end
  end
end
