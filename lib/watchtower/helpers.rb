module Watchtower
  module Helpers
    def self.constantize(class_or_name)
      case class_or_name
      when String
        class_or_name.constantize
      else
        class_or_name
      end
    end
  end
end
