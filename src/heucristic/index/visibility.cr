require "compiler/crystal/syntax"

module Heucristic
  module Index
    enum Visibility
      Public
      Protected
      Private

      def self.from(modifier : Crystal::Visibility) : Visibility
        case modifier
        in .public?    then Public
        in .protected? then Protected
        in .private?   then Private
        end
      end
    end
  end
end
