module Watchtower
  # Used to run triggers on a change.
  module Dispatch
    # Runs each of `triggers` that `change` is relevant to on every record of its audience. Triggers sharing an
    # observing class and a callback run it once per record.
    def self.run(triggers, change)
      triggers.group_by { |trigger| [ trigger.observing_class, trigger.callback ] }.each do |(observing_class, callback), group|
        audience = audience(observing_class, group, change)
        next unless audience

        audience.find_each do |observing_record|
          Helpers.evaluate(callback, observing_record)
          Rails.logger.debug { "Executed Watchtower callback for #{observing_record.class} #{observing_record.id}: #{callback}" }
        end
      end
    end

    def self.audience(observing_class, triggers, change)
      primary_key = observing_class.arel_table[observing_class.primary_key]
      scopes = triggers.flat_map do |trigger|
        change.watches_of(trigger).select { |watch| relevant?(watch, change) }.flat_map { |watch| Audience.new(trigger, watch).scopes(change) }
      end
      return nil if scopes.empty?

      audience = scopes.map { |scope| observing_class.where(observing_class.primary_key => scope.select(primary_key)) }.reduce(:or)
      includes = triggers.filter_map(&:includes)
      includes.any? ? audience.includes(*includes) : audience
    end

    # Whether `change` fires `watch`: a destroy, or a change to a watched attribute, always does, and any change does
    # when the watch names no attributes.
    def self.relevant?(watch, change)
      change.destroyed || watch.attributes.empty? || change.changed_attributes.intersect?(watch.attributes.map(&:to_s))
    end
  end
end
