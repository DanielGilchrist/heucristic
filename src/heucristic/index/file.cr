require "./def"
require "./namespace"
require "./mixin"
require "./instance_var"
require "./alias"
require "./constant"
require "./macro_def"

module Heucristic
  module Index
    record File,
      path : String,
      defs : Array(Def),
      namespaces : Array(Namespace),
      mixins : Array(Mixin),
      instance_vars : Array(InstanceVar),
      aliases : Array(Alias),
      constants : Array(Constant),
      macros : Array(MacroDef) = Array(MacroDef).new do
      def fingerprint : String
        String.build do |io|
          defs.each do |entry|
            io << entry.identity << ':' << entry.return_type << ':' << entry.yields << '\n'
          end
          namespaces.each { |entry| io << entry.keyword << ' ' << entry.name << '\n' }
          namespaces.each do |entry|
            next unless entry.is_a?(ClassNamespace)

            io << entry.name << '<' << entry.superclass << entry.type_vars
            io << entry.abstract_type << '\n'
          end
          mixins.each do |entry|
            io << entry.owner << ' ' << entry.kind << ' ' << entry.target << '\n'
          end
          instance_vars.each do |entry|
            io << entry.owner << ' ' << entry.name << ' ' << entry.type << '\n'
          end
          aliases.each { |entry| io << "alias " << entry.name << ' ' << entry.target << '\n' }
          constants.each { |entry| io << entry.name << " = " << entry.value << '\n' }
          macros.each { |entry| io << "macro " << entry.owner << ' ' << entry.name << '\n' }
        end
      end
    end
  end
end
