require "./identity"
require "./macro_site"
require "./owner"

module Heucristic
  module Index
    struct PrivateOwners
      def self.of(sites : Array(MacroSite)) : PrivateOwners
        paths = Hash(String, String?).new
        sites.each do |site|
          current = paths.fetch(site.owner) { site.private_to }
          paths[site.owner] = current == site.private_to ? current : nil
        end
        owners = Hash(String, String).new
        paths.each { |owner, path| owners[owner] = path if path }
        new(owners)
      end

      def initialize(@paths : Hash(String, String)) : Nil
      end

      def retarget(owner : Owner) : Owner
        owner.is_a?(Identity) ? retarget(owner) : owner
      end

      def retarget(identity : Identity) : Identity
        return identity unless identity.is_a?(Public)

        path = @paths[identity.name]?
        path ? FilePrivate.new(identity.name, path) : identity
      end
    end
  end
end
