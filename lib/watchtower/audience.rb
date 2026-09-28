module Watchtower
  # Used to find the records of the observing class that a change reaches through one watch of a trigger: the
  # owners the changed record has after the change, and when the change moved or destroyed it, its previous owners,
  # which the association join no longer reaches. The previous owners are found from what the change carries (its
  # previous foreign keys, or the `affects:` ids of a destroyed record), or, for a destroyed record that the records
  # an association passes through point at, from its id, and for a polymorphic source its type.
  class Audience
    def initialize(trigger, watch)
      @trigger = trigger
      @watch = watch
    end

    # The relations of the observing class that hold the audience: none, one or two.
    def scopes(change)
      [ current(change), previous_owners(change) ].compact
    end

    private

    def observing_class
      @trigger.observing_class
    end

    def reflection
      @watch.reflection
    end

    def current(change)
      return change.record && Helpers.evaluate(@trigger.affects, change.record) unless reflection
      return observing_class.where(reflection.foreign_key => change.record_id) if reflection.belongs_to?
      return nil if change.destroyed || change.record.nil?

      observing_class.joins(reflection.name).where(reflection.klass.table_name => { reflection.klass.primary_key => change.record_id })
    end

    def previous_owners(change)
      unless reflection
        ids = change.previous_owner_ids[@trigger.key]
        return ids.present? ? observing_class.where(observing_class.primary_key => ids) : nil
      end

      key_reflection = @watch.foreign_key_reflection
      return previous_owners_by_foreign_key(key_reflection, change.previous_foreign_keys) if key_reflection

      previous_owners_of_destroyed_source(change) if change.destroyed
    end

    # The owners the changed record's previous foreign keys reach through `key_reflection`. Nil when the previous
    # key is nil, or when a polymorphic previous type names a class other than the one `key_reflection` belongs to.
    def previous_owners_by_foreign_key(key_reflection, previous_foreign_keys)
      key = previous_foreign_keys[key_reflection.foreign_key.to_s]
      return nil if key.nil?
      return nil if key_reflection.type && previous_foreign_keys[key_reflection.type.to_s] != key_reflection.active_record.polymorphic_name
      return observing_class.where(key_reflection.active_record_primary_key => key) unless reflection.through_reflection?

      observing_class.joins(reflection.through_reflection.name).where(key_reflection.active_record.table_name => { key_reflection.active_record_primary_key => key })
    end

    # The owners whose through records point at the destroyed record, as in `has_many :publishers, through: :books`,
    # where each `Book` holds the `Publisher`'s key. Nil unless the association passes through another to a
    # `belongs_to` source.
    def previous_owners_of_destroyed_source(change)
      return nil unless reflection.through_reflection?

      source = reflection.source_reflection
      return nil unless source.belongs_to? && !source.through_reflection?

      keys = { source.foreign_key => change.record_id }
      keys[source.foreign_type] = change.record_type.constantize.polymorphic_name if source.polymorphic?
      observing_class.joins(reflection.through_reflection.name).where(source.active_record.table_name => keys)
    end
  end
end
