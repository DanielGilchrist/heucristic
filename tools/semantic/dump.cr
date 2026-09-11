require "compiler/requires"
require "json"
require "./site"
require "./header"

module Semantic
  class Dump
    def initialize(@entry : String, @root : String) : Nil
      @source = String::Builder.new
      @sites = Array(Site).new
      @line = 0
    end

    def write(io : IO) : Nil
      started = Time.instant
      program = Crystal::Program.new
      program.filename = @entry
      program.color = false
      program.wants_doc = false
      parser = Crystal::Parser.new(%(require "prelude"\n) + File.read(@entry))
      parser.filename = @entry
      program.top_level_semantic(parser.parse)
      collect(program)
      elapsed = Time.instant - started
      {
        crystal:    Crystal::VERSION,
        elapsed_ms: elapsed.total_milliseconds.round,
        source:     @source.to_s,
        sites:      @sites,
      }.to_json(io)
    rescue error : Crystal::CodeError
      {
        error: error.to_s.lines.first?.try(&.strip) || error.class.name,
        trace: error.to_s,
      }.to_json(io)
    rescue error : Exception
      {error: error.message || error.class.name}.to_json(io)
    end

    private def collect(program : Crystal::Program) : Nil
      all_types(program).each do |type|
        next unless type.is_a?(Crystal::ModuleType)
        next if type.is_a?(Crystal::LibType)

        generated = generated_defs(type, false) + generated_defs(type.metaclass, true)
        parents = project?(type) ? module_parents(type) : Array(String).new
        next if generated.empty? && parents.empty?

        reopen(type, generated, parents)
      end
    end

    private def all_types(program : Crystal::Program) : Array(Crystal::Type)
      found = Array(Crystal::Type).new
      pending = [program] of Crystal::Type
      while (container = pending.pop?)
        next unless container.is_a?(Crystal::ModuleType)

        container.types?.try &.each_value do |type|
          found << type
          pending << type
        end
      end
      found
    end

    private def generated_defs(type : Crystal::Type, metaclass : Bool) : Array(Generated)
      found = Array(Generated).new
      return found unless type.is_a?(Crystal::ModuleType)

      type.defs.try &.each_value do |overloads|
        overloads.each do |entry|
          definition = entry.def
          next if definition.name == "allocate"

          location = definition.location
          filename = location.try(&.filename)
          next unless filename.is_a?(Crystal::VirtualFile)

          found << Generated.new(definition, metaclass, filename)
        end
      end
      found
    end

    private def module_parents(type : Crystal::ModuleType) : Array(String)
      parents = type.parents || Array(Crystal::Type).new
      parents.compact_map do |parent|
        next if type.is_a?(Crystal::ClassType) && parent == type.superclass
        next if parent.is_a?(Crystal::ClassType)
        next unless parent.is_a?(Crystal::ModuleType)

        parent.to_s
      end
    end

    private def project?(type : Crystal::Type) : Bool
      locations = type.locations
      return false unless locations

      locations.any? do |location|
        path = location.original_filename
        path && path.starts_with?(@root) && !path.starts_with?(File.join(@root, "lib"))
      end
    end

    private def reopen(
      type : Crystal::ModuleType,
      generated : Array(Generated),
      parents : Array(String),
    ) : Nil
      emit(Header.reopen(type))
      parents.each { |parent| emit("  include ::#{parent}") }
      generated.each do |item|
        header = Header.def(item.definition, item.metaclass)
        header.each_line.with_index do |line, index|
          @sites << Site.of(@line + 1, type.to_s, item) if index.zero?
          emit("  #{line.chomp}")
        end
        emit("  end")
      end
      emit("end")
      emit("")
    end

    private def emit(text : String) : Nil
      @source << text << '\n'
      @line += 1
    end
  end
end
