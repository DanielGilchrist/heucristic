require "../../src/heucristic/index/workspace"
require "../../src/heucristic/index/macro_site"
require "../../src/heucristic/resolve/types"
require "../../src/heucristic/resolve/methods"
require "../../src/heucristic/resolve/receiver"
require "../../src/heucristic/check/suite"
require "../../src/heucristic/check/settled"

module Score
  record Corpus,
    root : String,
    workspace : Heucristic::Index::Workspace,
    sites : Array(Heucristic::Index::Sites),
    types : Heucristic::Resolve::Types,
    methods : Heucristic::Resolve::Methods,
    receiver : Heucristic::Resolve::Receiver,
    shim_roots : Array(String),
    compiled : Set(String)?,
    main_files : Set(String)?,
    origins : Hash(String, Heucristic::Index::MacroSite) do
    def settled : Heucristic::Check::Settled
      Heucristic::Check::Settled.new(
        @workspace,
        @types,
        @methods.descendants,
        !@compiled.nil?,
        Set(String).new,
        @compiled || Set(String).new,
        @root,
        @shim_roots,
      )
    end

    def environment(settled : Heucristic::Check::Settled) : Heucristic::Check::Environment
      Heucristic::Check::Environment.new(@workspace, @types, @methods, @receiver, settled, @root)
    end

    def suite(settled : Heucristic::Check::Settled) : Heucristic::Check::Suite
      Heucristic::Check::Suite.new(environment(settled))
    end

    def relative(path : String) : String
      path.sub(@root + "/", "")
    end

    def in_lib?(path : String) : Bool
      path.starts_with?(File.join(@root, "lib") + "/")
    end
  end
end
