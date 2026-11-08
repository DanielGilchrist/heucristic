require "../spec_helper"
require "file_utils"

describe Heucristic::Disk do
  it "creates missing levels and tolerates existing ones" do
    root = File.join(Dir.tempdir, "heucristic-spec-disk-#{Process.pid}")
    begin
      nested = File.join(root, "a", "b", "c")
      Heucristic::Disk.make_tree(nested).should be_nil
      Heucristic::Disk.make_tree(nested).should be_nil
      Dir.exists?(nested).should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reports a path blocked by a file instead of retrying forever" do
    root = File.join(Dir.tempdir, "heucristic-spec-disk-blocked-#{Process.pid}")
    begin
      Dir.mkdir_p(root)
      File.write(File.join(root, "file"), "")
      blocked = File.join(root, "file", "x")
      Heucristic::Disk.make_tree(blocked).should be_a(Heucristic::Disk::Unwritable)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
