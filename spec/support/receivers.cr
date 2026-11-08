require "../../src/heucristic/index/collector"
require "../../src/heucristic/index/workspace"
require "../../src/heucristic/index/shims"
require "../../src/heucristic/resolve/receiver"
require "../../src/heucristic/syntax/cursor"

def receiver_at(source : String, line : Int32, column : Int32) : String
  receiver_at(source, line, column, Array(Heucristic::Index::MacroExpansion).new)
end

def receiver_at(
  source : String,
  line : Int32,
  column : Int32,
  expansions : Array(Heucristic::Index::MacroExpansion),
) : String
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "syntax error: #{tree.message}" if tree.is_a?(Heucristic::Syntax::Broken)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect(
      "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
    )
  )
  workspace.expand(Heucristic::Index::MacroTarget::Main, expansions)
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  shims = Heucristic::Index::Shims.new
  receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
  target = Heucristic::Syntax::Cursor.find(
    tree, Heucristic::Document::Point.new(line, column), "a.cr", SPEC_CRYSTAL, source
  )
  case target
  in Heucristic::Syntax::OnCall        then receiver.of_call(target.node, target.context).to_s
  in Heucristic::Syntax::OnVar         then receiver.variable(target.name, target.context).to_s
  in Heucristic::Syntax::OnInstanceVar then receiver.instance_var(target.name, target.context).to_s
  in Heucristic::Syntax::OnDef,
     Heucristic::Syntax::OnPath,
     Heucristic::Syntax::OnName,
     Heucristic::Syntax::OnRequire,
     Nil
    raise "cursor did not land on a call or variable at #{line}:#{column}"
  end
end

def receiver_of_size(source : String, line_text : String) : String
  receiver_of_size(source, line_text, Array(Heucristic::Index::MacroExpansion).new)
end

def receiver_of_size(
  source : String,
  line_text : String,
  expansions : Array(Heucristic::Index::MacroExpansion),
) : String
  line = source.lines.index!(&.includes?(line_text)) + 1
  column = source.lines[line - 1].index!(line_text) + line_text.rindex!("size") + 1
  receiver_at(source, line, column, expansions)
end

def expansion_at(
  source : String,
  call_text : String,
  name : String,
  expanded : String,
) : Heucristic::Index::MacroExpansion
  line = source.lines.index!(&.includes?(call_text)) + 1
  column = source.lines[line - 1].index!(call_text) + 1
  Heucristic::Index::MacroExpansion.new("a.cr", line, column, name, expanded)
end

def receiver_across(files : Hash(String, String), path : String, line_text : String) : String
  workspace = Heucristic::Index::Workspace.new
  trees = Hash(String, Crystal::ASTNode).new
  files.each do |name, source|
    tree = Heucristic::Syntax.parse(source, name)
    raise "syntax error in #{name}: #{tree.message}" if tree.is_a?(Heucristic::Syntax::Broken)

    trees[name] = tree
    workspace.update(
      Heucristic::Index::Collector.collect(
        name, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
      )
    )
  end
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  shims = Heucristic::Index::Shims.new
  receiver = Heucristic::Resolve::Receiver.new(workspace, shims, types, methods)
  source = files[path]
  line = source.lines.index!(&.includes?(line_text)) + 1
  column = source.lines[line - 1].index!(line_text) + line_text.rindex!("size") + 1
  point = Heucristic::Document::Point.new(line, column)
  target = Heucristic::Syntax::Cursor.find(trees[path], point, path, SPEC_CRYSTAL, source)
  raise "cursor did not land on a call in #{path}" unless target.is_a?(Heucristic::Syntax::OnCall)

  receiver.of_call(target.node, target.context).to_s
end
