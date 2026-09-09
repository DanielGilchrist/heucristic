require "../../spec_helper"
require "file_utils"

describe Heucristic::Index::EmbeddedShims do
  it "carries every shim file from the repository" do
    names = Heucristic::Index::EmbeddedShims::FILES.map(&.[0])
    names.should contain("enumerable.cr")
    names.should contain("generated/numbers.cr")
    Heucristic::Index::EmbeddedShims::FILES.each do |(_, contents)|
      contents.should_not be_empty
    end
  end

  it "materializes the files into the cache and is idempotent" do
    cache = File.join(Dir.tempdir, "heucristic-spec-cache-#{Process.pid}")
    ENV["XDG_CACHE_HOME"] = cache
    begin
      stale = File.join(cache, "heucristic", "shims", "0000000000000000")
      Dir.mkdir_p(stale)
      root = Heucristic::Index::EmbeddedShims.materialize
      root.should be_a(String)
      root.as?(String).try(&.ends_with?(Heucristic::Index::EmbeddedShims.digest)).should be_true
      root.as?(String).try { |dir| File.exists?(File.join(dir, "enumerable.cr")) }.should be_true
      Heucristic::Index::EmbeddedShims.materialize.should eq(root)
      Dir.exists?(stale).should be_false
    ensure
      ENV.delete("XDG_CACHE_HOME")
      FileUtils.rm_rf(cache)
    end
  end
end
