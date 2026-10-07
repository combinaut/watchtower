module Watchtower
  # Used to find the records of the observing class that a change reaches through one watch of a trigger: the
  # watchers the changed record has after the change, and when the change moved or destroyed it, its previous watchers,
  # which the association join no longer reaches. The previous watchers are found from what the change carries (its
  # previous foreign keys, or the `affects:` ids of a destroyed record), or, for a destroyed record that the records
  # an association passes through point at, from its id, and for a polymorphic source its type.
  class Watchers
    def initialize(trigger, watch)
      @trigger = trigger
      @watch = watch
    end

    # The relations of the observing class that hold the watchers any of `changes` reaches. Each kind of lookup, the
    # current watchers, the previous watchers by foreign key and those of destroyed sources, is one relation for all of
    # `changes`, except an `affects:` scope, which is evaluated for each change.
    def scopes(changes)
      [ *current_scopes(changes), *previous_scopes(changes) ]
    end

    # The watchers the record has after the change: none once it is destroyed, or, unless the observing class `belongs_to` it,
    # once it can no longer be loaded.
    def after(change)
      return observing_class.none if change.destroyed

      current(change) || observing_class.none
    end

    # The watchers the record had before the change: for a destroy or a move, its previous watchers, and otherwise the
    # watchers it has after the change. Nil when they cannot be known:
    #   - a scoped association, whose scope can take in or leave out the record without any key changing
    #   - an `affects:` scope, on anything but a destroy
    #   - through an association whose source is itself a `has_many :through`, a change to one of the record's own
    #     `belongs_to` foreign keys
    def before(change)
      return nil if scoped?
      return previous_watchers(change) || current(change) || observing_class.none if change.destroyed
      return previous_watchers(change) || observing_class.none if moved?(change)
      return nil if possibly_moved?(change)

      after(change)
    end

    private

    def observing_class
      @trigger.observing_class
    end

    def reflection
      @watch.reflection
    end

    def moved?(change)
      @watch.foreign_key_attributes.intersect?(change.changed_attributes)
    end

    def scoped?
      reflection&.chain&.any?(&:scope)
    end

    def possibly_moved?(change)
      return true unless reflection
      return false if reflection.belongs_to? || @watch.foreign_key_reflection
      # Through a `belongs_to` source, the record an association passes through holds the key, so the watched record
      # cannot move by changing its own.
      return false if reflection.source_reflection.belongs_to? && !reflection.source_reflection.through_reflection?

      record_class = change.record_type.constantize
      foreign_keys = record_class.reflect_on_all_associations(:belongs_to).flat_map { |each| [ each.foreign_key.to_s, each.foreign_type&.to_s ] }.compact
      foreign_keys.intersect?(change.changed_attributes)
    end

    def current(change)
      current_scopes([ change ]).first
    end

    def previous_watchers(change)
      previous_scopes([ change ]).first
    end

    # The relations holding the watchers `changes` have after them: for an `affects:` scope, its result for each
    # change whose record can still be loaded, and otherwise one relation for all of `changes`.
    def current_scopes(changes)
      return changes.filter_map { |change| change.record && Helpers.evaluate(@trigger.affects, change.record) } unless reflection
      return [ observing_class.where(reflection.foreign_key => changes.map(&:record_id)) ] if reflection.belongs_to?

      ids = changes.reject { |change| change.destroyed || change.record.nil? }.map(&:record_id)
      return [] if ids.empty?

      [ observing_class.joins(reflection.name).where(reflection.klass.table_name => { reflection.klass.primary_key => ids }) ]
    end

    # The relations holding the watchers `changes` had before a move or destroy: from the `affects:` ids a destroy
    # carries, from the previous foreign keys, or, for destroyed records an association's through records point at,
    # from their ids.
    def previous_scopes(changes)
      unless reflection
        ids = changes.flat_map { |change| change.previous_watcher_ids[@trigger.key] || [] }
        return ids.empty? ? [] : [ observing_class.where(observing_class.primary_key => ids) ]
      end

      key_reflection = @watch.foreign_key_reflection
      return previous_by_foreign_key(key_reflection, changes) if key_reflection

      previous_of_destroyed_sources(changes.select(&:destroyed))
    end

    # The watchers the changes' previous foreign keys reach through `key_reflection`. A change whose previous key is
    # nil, or whose polymorphic previous type names a class other than the one `key_reflection` belongs to, reaches
    # none.
    def previous_by_foreign_key(key_reflection, changes)
      keys = changes.filter_map do |change|
        previous = change.previous_foreign_keys
        next if key_reflection.type && previous[key_reflection.type.to_s] != key_reflection.active_record.polymorphic_name

        previous[key_reflection.foreign_key.to_s]
      end
      return [] if keys.empty?
      return [ observing_class.where(key_reflection.active_record_primary_key => keys) ] unless reflection.through_reflection?

      [ observing_class.joins(reflection.through_reflection.name).where(key_reflection.active_record.table_name => { key_reflection.active_record_primary_key => keys }) ]
    end

    # The watchers whose through records point at the destroyed records, as in `has_many :publishers, through: :books`,
    # where each `Book` holds the `Publisher`'s key. None unless the association passes through another to a
    # `belongs_to` source. A polymorphic source gets one relation for each type destroyed.
    def previous_of_destroyed_sources(changes)
      return [] if changes.empty? || !reflection.through_reflection?

      source = reflection.source_reflection
      return [] unless source.belongs_to? && !source.through_reflection?

      changes.group_by(&:record_type).map do |record_type, typed|
        keys = { source.foreign_key => typed.map(&:record_id) }
        keys[source.foreign_type] = record_type.constantize.polymorphic_name if source.polymorphic?
        observing_class.joins(reflection.through_reflection.name).where(source.active_record.table_name => keys)
      end
    end
  end
end
