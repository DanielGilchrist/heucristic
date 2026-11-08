require "./identity"
require "./macro_site"
require "./owner"
require "./reopening"

module Heucristic
  module Index
    struct PrivateOwners
      def self.of(sites : Array(MacroSite), reopenings : Array(Reopening)) : PrivateOwners
        stances = Hash(String, Set(String?)).new
        reopenings.each { |entry| (stances[entry.name] ||= Set(String?).new) << entry.private_to }
        sites.each { |site| (stances[site.owner] ||= Set(String?).new) << site.private_to }
        new(stances)
      end

      def initialize(@stances : Hash(String, Set(String?))) : Nil
      end

      def retarget(owner : Owner) : Owner?
        owner.is_a?(Identity) ? retarget(owner) : owner
      end

      def retarget(identity : Identity) : Identity?
        return identity unless identity.is_a?(Public)

        stance = @stances[identity.name]?
        return identity unless stance
        return if stance.size > 1

        path = stance.first
        path ? FilePrivate.new(identity.name, path) : identity
      end
    end
  end
end
