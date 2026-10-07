module Watchtower
  # Used to run triggers on a change.
  module Dispatch
    # Runs triggers on the watchers their changes reach, given as `[trigger, change]` pairs: each change a commit
    # fires a trigger on, or the one change a save fires it on. Triggers sharing an observing class, a callback and an
    # `around:` form a group, which runs inside one `around:` when it declares one. A callback that does not want the
    # change runs once per watcher however many of the group's changes reach it, and the group's watchers are found
    # together (`watchers`). A callback that wants the change (`Helpers.callback_wants_change?`) runs once per watcher
    # for each change that reaches it, given the `Watchtower::WatcherChange` for that change (`watcher_changes`).
    def self.run(pairs)
      pairs.group_by { |trigger, _change| [ trigger.observing_class, trigger.callback, trigger.around ] }.each do |(observing_class, callback, around), group|
        runs =
          if Helpers.callback_wants_change?(callback, observing_class)
            group.group_by(&:last).filter_map do |change, change_pairs|
              watchers = watchers(observing_class, change_pairs)
              watchers && [ watchers, watcher_changes(observing_class, change_pairs.map(&:first), change) ]
            end
          else
            watchers = watchers(observing_class, group)
            watchers ? [ [ watchers, nil ] ] : []
          end
        next if runs.empty?

        run_callbacks = -> { runs.each { |watchers, watcher_changes| run_callback(callback, watchers, watcher_changes) } }
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

    # The watchers the `[trigger, change]` pairs reach, as one relation, or nil when none can be reached. Each watch
    # of each trigger looks its watchers up once for all of the changes it is relevant to (`Watchers#scopes`).
    def self.watchers(observing_class, pairs)
      primary_key = observing_class.arel_table[observing_class.primary_key]
      scopes = pairs.group_by(&:first).flat_map do |trigger, trigger_pairs|
        changes = trigger_pairs.map(&:last)
        trigger.watches.flat_map do |watch|
          reaching = changes.select { |change| change.watches_of(trigger).include?(watch) && relevant?(watch, change) }
          reaching.empty? ? [] : Watchers.new(trigger, watch).scopes(reaching)
        end
      end
      return nil if scopes.empty?

      watchers = scopes.map { |scope| observing_class.where(observing_class.primary_key => scope.select(primary_key)) }.reduce(:or)
      includes = pairs.map(&:first).uniq.filter_map(&:includes)
      includes.any? ? watchers.includes(*includes) : watchers
    end

    # Whether `change` fires `watch`: a destroy, a move, or a change to a watched attribute always does, and any
    # other change does when the watch names no attributes and is not `foreign_keys_only`. A change can never fire a
    # watch whose polymorphic association it does not belong to (`reachable?`).
    def self.relevant?(watch, change)
      return false unless reachable?(watch, change)

      watched = watch.foreign_key_attributes + watch.attributes.map(&:to_s)
      return true if change.destroyed || change.changed_attributes.intersect?(watched)

      !watch.foreign_keys_only && watch.attributes.empty?
    end

    # Whether the changed record can belong to the watch's association. Through a polymorphic `has_many ... as:`,
    # e.g. `has_many :comments, as: :commentable`, a record belongs to a watcher only when its type names the
    # watcher's model now or did before a move or destroy, so a comment on a `Book` never reaches an `Author`. Any
    # other watch, or a change whose type is unknown, is reachable.
    def self.reachable?(watch, change)
      reflection = watch.reflection
      return true unless reflection && !reflection.through_reflection? && reflection.type

      type = reflection.type.to_s
      types = [ change.record&.read_attribute(type), change.previous_foreign_keys[type] ].compact
      types.empty? || types.include?(reflection.active_record.polymorphic_name)
    end
  end
end
