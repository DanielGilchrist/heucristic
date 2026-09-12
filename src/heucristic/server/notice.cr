module Heucristic
  module Server
    enum Notice
      Indexed
      Macros
      Compiler

      def method : String
        "$/heucristic/#{to_s.downcase}"
      end
    end
  end
end
