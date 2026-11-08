require "json"
require "../../src/heucristic/index/workspace"
require "../../src/heucristic/index/macro_site"
require "../../src/heucristic/resolve/types"

module Score
  class Verifier
    enum Fit
      Same
      Unknown
      Conflict
    end

    enum Kind
      Agree
      OverApproximate
      Unverified
      Disagree
      Unseen
    end

    record Verdict, kind : Kind, message : String = ""
    record Location, path : String, line : Int32 do
      def key : String
        "#{path}:#{line}"
      end
    end

    record Same, locations : Array(Location)
    record Declares, locations : Array(Location)
    record Undecided, reason : String
    record Different

    alias Entry = Heucristic::Index::Def
    alias Match = Same | Declares | Undecided | Different

    record Probe, path : String, line : Int32, column : Int32, result : String

    MACRO_OPEN       = /\{%-?\s*(?:if|unless|for|begin|case|while|macro)\b/
    MACRO_CLOSE      = /\{%-?\s*end\b/
    DECLARATION_CALL = /\A\s*(?:private\s+)?(?:record|getter|property|class_getter|delegate)\b/
    TYPE_HEADER      = /\A\s*(?:\w+\s+)*(?:class|struct)\s+([\w:]+)/
    IMPLICIT         = {"Reference", "Object", "Struct", "Value"}

    def initialize(
      @root : String,
      @main : String,
      @workspace : Heucristic::Index::Workspace,
      @types : Heucristic::Resolve::Types,
      @origins : Hash(String, Heucristic::Index::MacroSite),
    ) : Nil
      @lines = Hash(String, Array(String)).new
      @sites_at = Hash(String, Int32).new(0)
      @origins.each_value do |site|
        expanded = expansion_of(site)
        @sites_at["#{expanded}:#{site.name}"] += 1 if expanded
      end
    end

    def judge(
      probe : Probe,
      ours : Array(Entry),
    ) : Verdict?
      theirs = compiler_targets(probe)
      return unless theirs
      return Verdict.new(:unseen, "compiler reports no implementation") if theirs.empty?
      if theirs.size == 1 && theirs[0].path == "<unknown>"
        return Verdict.new(:unverified, "the compiler's def has no source location")
      end
      if ours.empty?
        return Verdict.new(:unverified, "none of our targets is in a compiled file")
      end

      conclude(ours, theirs, probe.result)
    end

    private def conclude(
      ours : Array(Entry),
      theirs : Array(Location),
      result : String,
    ) : Verdict
      matches = ours.map { |entry| match(entry, theirs) }
      undecided = matches.compact_map { |found| found.as?(Undecided) }
      unless undecided.empty?
        return Verdict.new(:unverified, undecided.first.reason)
      end

      consumed = Array(Location).new
      declared = false
      extras = Array(Entry).new
      matches.each_with_index do |found, index|
        case found
        in Same then consumed.concat(found.locations)
        in Declares
          consumed.concat(found.locations)
          declared = true
        in Different then extras << ours[index]
        in Undecided then nil
        end
      end
      remaining = theirs.reject { |location| consumed.any? { |taken| taken.key == location.key } }
      matched = ours - extras
      return Verdict.new(:agree) if extras.empty? && remaining.empty? && !declared
      if declared && extras.empty? && remaining.empty?
        return Verdict.new(:over_approximate, "ours is declared above the compiler's owner")
      end

      reconcile(matched, extras, remaining, result)
    end

    private def reconcile(
      matched : Array(Entry),
      extras : Array(Entry),
      remaining : Array(Location),
      result : String,
    ) : Verdict
      defs = remaining.compact_map { |location| def_at(location) }
      if defs.size != remaining.size
        return Verdict.new(:unverified, "compiler targets are not in the index")
      end
      unless defs.empty?
        message = "compiler also reaches #{names(defs)}, ours: #{names(matched + extras)}"
        return Verdict.new(:disagree, message)
      end
      if matched.empty?
        return Verdict.new(:disagree, "no compiler target matches #{names(extras)}")
      end

      fits = extras.map { |entry| fit(entry, matched, result) }
      if (index = fits.index(Fit::Conflict))
        message = "#{extras[index].qualified} returns a type no compiler target does"
        return Verdict.new(:disagree, message)
      end

      note = fits.includes?(Fit::Unknown) ? " (return types unrestricted)" : ""
      Verdict.new(:over_approximate, "extra #{names(extras)}#{note}")
    end

    private def fit(entry : Entry, references : Array(Entry), result : String) : Fit
      return Fit::Same if entry.name == "initialize"

      restriction = entry.return_type
      return Fit::Unknown if restriction.is_a?(Heucristic::Index::Unrestricted)

      text = restriction.to_s
      return Fit::Unknown if text.matches?(/\bself\b|\b[A-Z]\b/)

      members = members(text)
      return Fit::Same if members.all? { |member| members(result).includes?(member) }

      known = references.reject { |other| other.return_type.is_a?(Heucristic::Index::Unrestricted) }
      return Fit::Unknown if known.empty?

      known.any? { |other| members(other.return_type.to_s) == members } ? Fit::Same : Fit::Conflict
    end

    private def members(type : String) : Array(String)
      found = Array(String).new
      depth = 0
      current = String::Builder.new
      type.each_char do |char|
        depth += 1 if char == '('
        depth -= 1 if char == ')'
        if char == '|' && depth.zero?
          found << current.to_s.strip
          current = String::Builder.new
        else
          current << char
        end
      end
      found << current.to_s.strip
      found.sort!
    end

    private def names(defs : Array(Entry)) : String
      defs.map(&.qualified).join(", ")
    end

    private def match(entry : Entry, theirs : Array(Location)) : Match
      line = entry.name_span.start_line.to_i + 1
      exact = theirs.find { |location| location.path == entry.path && location.line == line }
      return Same.new([exact]) if exact
      declared = declared_above(entry, theirs)
      return declared if declared
      return Different.new if entry.abstract_def
      return generated(entry, line, theirs) if entry.path.starts_with?("<macros")
      return restated(entry, theirs) if entry.path.includes?("/shims/generated/")

      implicit = implicit_constructor(entry, theirs)
      return implicit if implicit

      expanded_region(entry, line, theirs)
    end

    private def declared_above(entry : Entry, theirs : Array(Location)) : Match?
      owner = entry.owner
      return unless owner.is_a?(Heucristic::Index::Identity)

      theirs.each do |location|
        found = def_at(location)
        return unresolved(entry, Undecided.new("#{location.key} is not in the index")) unless found

        found_owner = found.owner
        unless found_owner.is_a?(Heucristic::Index::Identity) && found_owner != owner &&
               descends?(found_owner, owner)
          return unresolved(entry, Different.new)
        end
      end
      Declares.new(theirs)
    end

    private def unresolved(entry : Entry, outcome : Undecided | Different) : Match?
      entry.abstract_def ? outcome : nil
    end

    private def generated(entry : Entry, line : Int32, theirs : Array(Location)) : Match
      site = @origins["#{entry.path}:#{line}"]?
      return Undecided.new("no site recorded for #{entry.path}:#{line}") unless site

      expanded = expansion_of(site)
      return Undecided.new("#{entry.qualified} has no expansion site") unless expanded

      found = theirs.find { |location| location.key == expanded }
      return Different.new unless found
      return looped(found) if loop_line?(found)

      if @sites_at["#{expanded}:#{site.name}"] > 1
        return Undecided.new("several `#{site.name}` defs are generated at #{expanded}")
      end

      Same.new([found])
    end

    private def restated(entry : Entry, theirs : Array(Location)) : Match
      statements = theirs.reject { |location| line_text(location).includes?("def ") }
      return Different.new if statements.size != theirs.size

      looping = theirs.find { |location| loop_line?(location) }
      return looped(looping) if looping

      twins = @workspace.named(entry.name).count do |other|
        other.path == entry.path && other.owner == entry.owner && other.receiver == entry.receiver
      end
      if twins > 1
        return Undecided.new("#{twins} restated overloads of #{entry.qualified}")
      end

      Same.new(theirs)
    end

    private def implicit_constructor(entry : Entry, theirs : Array(Location)) : Match?
      return unless entry.name == "new"

      owner = entry.owner
      return unless owner.is_a?(Heucristic::Index::Identity)

      synthesized = @workspace.namespaces(owner).any? do |namespace|
        namespace.path == entry.path && namespace.name_span == entry.name_span
      end
      return unless synthesized

      theirs.each do |location|
        header = TYPE_HEADER.match(line_text(location))
        return Different.new unless header

        name = header[1]
        supplies = IMPLICIT.includes?(name) && descends?(owner, Heucristic::Index::Public.new(name))
        named = owner.name == name || owner.name.ends_with?("::#{name}")
        return Different.new unless supplies || named
      end
      Same.new(theirs)
    end

    private def expanded_region(entry : Entry, line : Int32, theirs : Array(Location)) : Match
      theirs.each do |location|
        next unless location.path == entry.path

        region = region_at(location)
        next unless region.includes?(line)
        return looped(location) if loop_line?(location)

        siblings = @workspace.file(entry.path).try do |file|
          file.defs.count do |other|
            other.name == entry.name && region.includes?(other.name_span.start_line.to_i + 1)
          end
        end
        if siblings != 1
          return Undecided.new("#{siblings} `#{entry.name}` defs in the region at #{location.key}")
        end

        return Same.new([location])
      end
      Different.new
    end

    private def loop_line?(location : Location) : Bool
      text = line_text(location).lstrip
      text.starts_with?("{% for") || text.includes?("expand_div")
    end

    private def looped(location : Location) : Undecided
      Undecided.new("#{location.key} is a loop that defines the name for several owners")
    end

    private def region_at(location : Location) : Range(Int32, Int32)
      lines = source(location.path)
      first = lines[location.line - 1]?
      return location.line..location.line unless first
      return declaration_end(lines, location.line) if DECLARATION_CALL.matches?(first)
      return location.line..location.line unless first.lstrip.starts_with?("{%")

      depth = 0
      (location.line..lines.size).each do |number|
        text = lines[number - 1]
        depth += text.scan(MACRO_OPEN).size - text.scan(MACRO_CLOSE).size
        return location.line..number if depth <= 0
      end
      location.line..lines.size
    end

    private def declaration_end(lines : Array(String), start : Int32) : Range(Int32, Int32)
      finish = start
      while lines[finish - 1]?.try(&.rstrip.matches?(/[,(]\z/))
        finish += 1
      end
      start..finish
    end

    private def descends?(
      owner : Heucristic::Index::Identity,
      ancestor : Heucristic::Index::Identity,
    ) : Bool
      return true if owner == ancestor

      chain = @types.ancestors(owner)
      chain.is_a?(Array(Heucristic::Index::Identity)) && chain.includes?(ancestor)
    end

    private def def_at(location : Location) : Entry?
      @workspace.file(location.path).try do |file|
        file.defs.find { |entry| entry.name_span.start_line.to_i + 1 == location.line }
      end
    end

    private def expansion_of(site : Heucristic::Index::MacroSite) : String?
      path = site.expanded_path
      line = site.expanded_line
      path && line ? "#{path}:#{line}" : nil
    end

    private def line_text(location : Location) : String
      source(location.path)[location.line - 1]? || ""
    end

    private def source(path : String) : Array(String)
      @lines[path] ||= ::File.exists?(path) ? ::File.read_lines(path) : Array(String).new
    end

    private def compiler_targets(probe : Probe) : Array(Location)?
      output = IO::Memory.new
      status = Process.run(
        "crystal",
        {
          "tool", "implementations", "--no-color", "-f", "json",
          "-c", "#{probe.path}:#{probe.line}:#{probe.column}", File.join(@root, @main),
        },
        output: output, error: Process::Redirect::Close, chdir: @root
      )
      return unless status.success?

      found = JSON.parse(output.to_s)["implementations"]?.try(&.as_a?) || Array(JSON::Any).new
      locations = found.compact_map do |impl|
        line = impl["line"]?.try(&.as_i?)
        filename = impl["filename"]?.try(&.as_s?)
        line && filename ? Location.new(filename, line) : nil
      end
      locations.uniq!(&.key)
    end
  end
end
