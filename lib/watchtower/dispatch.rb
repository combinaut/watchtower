module Watchtower
  # Used to run triggers on a change.
  module Dispatch
    # Runs each of `triggers` that `change` is relevant to on every record of its audience. Triggers sharing an
    # observing class, a callback and an `around:` run the callback once per record, all of it inside that
    # `around:` when they declare one.
    def self.run(triggers, change)
      triggers.group_by { |trigger| [ trigger.observing_class, trigger.callback, trigger.around ] }.each do |(observing_class, callback, around), group|
        audience = audience(observing_class, group, change)
        next unless audience

        run_callbacks = -> { run_callback(callback, audience) }
        around ? around.call(&run_callbacks) : run_callbacks.call
      end
    end

    def self.run_callback(callback, audience)
      audience.find_each do |observing_record|
        Helpers.evaluate(callback, observing_record)
        Rails.logger.debug { "Executed Watchtower callback for #{observing_record.class} #{observing_record.id}: #{callback}" }
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

    # Whether `change` fires `watch`: a destroy, a move, or a change to a watched attribute always does, and any
    # other change does when the watch names no attributes and is not `foreign_keys_only`.
    def self.relevant?(watch, change)
      watched = watch.foreign_key_attributes + watch.attributes.map(&:to_s)
      return true if change.destroyed || change.changed_attributes.intersect?(watched)

      !watch.foreign_keys_only && watch.attributes.empty?
    end
  end
end
