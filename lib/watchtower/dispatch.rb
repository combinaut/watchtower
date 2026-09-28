module Watchtower
  # Used to run triggers on a change.
  module Dispatch
    # Runs each of `triggers` that `change` is relevant to on every record of its audience.
    def self.run(triggers, change)
      triggers.each do |trigger|
        change.watches_of(trigger).select { |watch| relevant?(watch, change) }.each do |watch|
          Audience.new(trigger, watch).scopes(change).each do |audience|
            audience.includes(trigger.includes).find_each do |observing_record|
              Helpers.evaluate(trigger.callback, observing_record)
              Rails.logger.debug { "Executed Watchtower callback for #{observing_record.class} #{observing_record.id}: #{trigger.callback}" }
            end
          end
        end
      end
    end

    # Whether `change` fires `watch`: a destroy, or a change to a watched attribute, always does, and any change does
    # when the watch names no attributes.
    def self.relevant?(watch, change)
      change.destroyed || watch.attributes.empty? || change.changed_attributes.intersect?(watch.attributes.map(&:to_s))
    end
  end
end
