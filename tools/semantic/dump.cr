require "compiler/requires"
require "json"
require "./site"
require "./header"

module Semantic
  class Dump
    def initialize(@entry : String, @root : String, @defines : Array(String)) : Nil
      @source = String::Builder.new
      @sites = Array(Site).new
      @line = 0
    end

    def write(io : IO) : Nil
      started = Time.instant
      program = Crystal::Program.new
      @defines.each { |flag| program.flags << flag }
      {% if Crystal::Program.has_method?(:define_crystal_constants) %}
        program.user_flags.concat(@defines)
        program.define_crystal_constants
      {% end %}
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
        files:      files(program),
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
        next if type.is_a?(Crystal::LibType)
        declared_by_macro = macro_declared?(type)
        case type
        in Crystal::Const
          emit("::#{type} = #{constant_value(type.value)}") if declared_by_macro
        in Crystal::AliasType
          emit("alias ::#{type} = #{type.aliased_type}") if declared_by_macro
        in Crystal::ModuleType
          declaring = declared_by_macro ? declaring_file(type) : nil
          generated = generated_defs(type, false, declaring) +
                      generated_defs(type.metaclass, true, declaring)
          extended = extended_modules(type)
          macros = generated_macros(type)
          parents = project?(type) ? module_parents(type) : Array(String).new
          if generated.empty? && parents.empty? && extended.empty? && macros.empty?
            next unless declared_by_macro
          end

          reopen(type, generated, parents, extended, macros, declared_by_macro)
        in Crystal::Type then nil
        end
      end
    end

    private def macro_declared?(type : Crystal::Type) : Bool
      locations = type.locations
      return false if locations.nil? || locations.empty?

      locations.all? { |location| location.filename.is_a?(Crystal::VirtualFile) }
    end

    private def constant_value(value : Crystal::ASTNode) : String
      source = value.to_s
      reparses?(source) ? source : "uninitialized ::Nil"
    end

    private def reparses?(source : String) : Bool
      Crystal::Parser.parse(source)
      true
    rescue Crystal::SyntaxException
      false
    end

    private def files(program : Crystal::Program) : Array(String)
      found = Set(String).new
      program.requires.each { |path| found << path }
      ([program] of Crystal::Type).concat(all_types(program)).each do |type|
        type.locations.try &.each { |location| record_file(location, found) }
        next unless type.is_a?(Crystal::ModuleType)

        type.defs.try &.each_value do |overloads|
          overloads.each { |entry| record_file(entry.def.location, found) }
        end
        type.metaclass.as?(Crystal::ModuleType).try &.defs.try &.each_value do |overloads|
          overloads.each { |entry| record_file(entry.def.location, found) }
        end
      end
      found.to_a.sort!
    end

    private def record_file(location : Crystal::Location?, found : Set(String)) : Nil
      path = location.try(&.original_filename)
      found << path if path
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

    private def declaring_file(type : Crystal::Type) : Crystal::VirtualFile?
      type.locations.try &.each do |location|
        filename = location.filename
        return filename if filename.is_a?(Crystal::VirtualFile)
      end
      nil
    end

    private def generated_defs(
      type : Crystal::Type,
      metaclass : Bool,
      declaring : Crystal::VirtualFile?,
    ) : Array(Generated)
      found = Array(Generated).new
      return found unless type.is_a?(Crystal::ModuleType)

      type.defs.try &.each_value do |overloads|
        overloads.each do |entry|
          definition = entry.def
          next if definition.name == "allocate"

          location = definition.location
          filename = location.try(&.filename)
          if filename.is_a?(Crystal::VirtualFile)
            found << Generated.new(definition, metaclass, filename, nil)
          elsif declaring && location
            found << Generated.new(definition, metaclass, declaring, location)
          end
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

    private def extended_modules(type : Crystal::ModuleType) : Array(String)
      metaclass = type.metaclass
      return Array(String).new unless metaclass.is_a?(Crystal::ModuleType)

      parents = metaclass.parents || Array(Crystal::Type).new
      parents.compact_map do |parent|
        next unless parent.is_a?(Crystal::NonGenericModuleType)

        parent.to_s
      end
    end

    private def generated_macros(type : Crystal::ModuleType) : Array(Crystal::Macro)
      found = Array(Crystal::Macro).new
      type.macros.try &.each_value do |overloads|
        overloads.each { |entry| found << entry }
      end
      metaclass = type.metaclass
      if metaclass.is_a?(Crystal::ModuleType)
        metaclass.macros.try &.each_value do |overloads|
          overloads.each { |entry| found << entry }
        end
      end
      found
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
      extended : Array(String),
      macros : Array(Crystal::Macro),
      declared_by_macro : Bool,
    ) : Nil
      emit(declared_by_macro ? Header.declare(type) : Header.reopen(type))
      if declared_by_macro && type.is_a?(Crystal::EnumType)
        type.types?.try &.each do |name, member|
          emit("  #{name} = #{member.value}") if member.is_a?(Crystal::Const)
        end
      end
      parents.each { |parent| emit("  include ::#{parent}") }
      extended.each { |parent| emit("  extend ::#{parent}") }
      macros.each do |entry|
        emit("  #{Header.macro(entry)}")
        emit("  end")
      end
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
