module Watchtower
  # Used to run triggers on a change.
  module Dispatch
    # Runs each of `triggers` that `change` is relevant to on each of its watchers. Triggers sharing an
    # observing class, a callback and an `around:` run the callback once per record, all of it inside that
    # `around:` when they declare one. A callback that wants the change (`Helpers.callback_wants_change?`) is also
    # given the `Watchtower::WatcherChange` for each record, which is built only then (`watcher_changes`).
    def self.run(triggers, change)
      triggers.group_by { |trigger| [ trigger.observing_class, trigger.callback, trigger.around ] }.each do |(observing_class, callback, around), group|
        watchers = watchers(observing_class, group, change)
        next unless watchers

        watcher_changes = watcher_changes(observing_class, group, change) if Helpers.callback_wants_change?(callback, observing_class)
        run_callbacks = -> { run_callback(callback, watchers, watcher_changes) }
        around ? around.call(&run_callbacks) : run_callbacks.call
      end
    end

    def self.run_callback(callback, watchers, watcher_changes)
      watchers.find_each do |observing_record|
        if watcher_changes
          Helpers.evaluate_with_change(callback, observing_record, watcher_changes.call(observing_record))
        else
          Helpers.evaluate(callback, observing_record)
        end
        Rails.logger.debug { "Executed Watchtower callback for #{observing_record.class} #{observing_record.id}: #{callback}" }
      end
    end

    # Returns a lambda from a watcher to the `Watchtower::WatcherChange` `change` makes for it, across the watches of
    # `triggers` the change is relevant to. A watcher among the previous watchers and the current ones gets `:changed`,
    # among the current ones only `:added`, and among the previous ones only `:removed`. When any of those watches
    # cannot know the previous watchers, every watcher gets a nil `kind` and `previous_watchers`.
    def self.watcher_changes(observing_class, triggers, change)
      lookups = triggers.flat_map do |trigger|
        change.watches_of(trigger).select { |watch| relevant?(watch, change) }.map { |watch| Watchers.new(trigger, watch) }
      end
      primary_key = observing_class.primary_key
      befores = lookups.map { |lookup| lookup.before(change) }
      before_ids = befores.include?(nil) ? nil : befores.flat_map { |watchers| watchers.pluck(primary_key) }.to_set
      after_ids = lookups.flat_map { |lookup| lookup.after(change).pluck(primary_key) }.to_set
      previous_watchers = before_ids && observing_class.where(primary_key => before_ids.to_a)
      watchers = observing_class.where(primary_key => after_ids.to_a)

      lambda do |watcher|
        id = watcher.public_send(primary_key)
        WatcherChange.new(
          kind: before_ids && kind(before_ids.include?(id), after_ids.include?(id)),
          record: change.record,
          record_class: change.record_type.constantize,
          record_id: change.record_id,
          destroyed: change.destroyed,
          changed_attributes: change.changed_attributes,
          previous_watchers: previous_watchers,
          watchers: watchers
        )
      end
    end

    def self.kind(before, after)
      return :changed if before && after

      after ? :added : :removed
    end

    def self.watchers(observing_class, triggers, change)
      primary_key = observing_class.arel_table[observing_class.primary_key]
      scopes = triggers.flat_map do |trigger|
        change.watches_of(trigger).select { |watch| relevant?(watch, change) }.flat_map { |watch| Watchers.new(trigger, watch).scopes(change) }
      end
      return nil if scopes.empty?

      watchers = scopes.map { |scope| observing_class.where(observing_class.primary_key => scope.select(primary_key)) }.reduce(:or)
      includes = triggers.filter_map(&:includes)
      includes.any? ? watchers.includes(*includes) : watchers
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
