module Watchtower
  # A save or destroy of an observed record, as the triggers it fires read it. A change moves the record when it
  # changes a foreign key that ties the record to its watchers (`Observer::Watch#foreign_key_attributes`).
  #
  # @!attribute record_class
  #   @return [String] the record's base class name
  # @!attribute record_type
  #   @return [String] the record's own class name, which differs from `record_class` for an STI subclass
  # @!attribute record_id
  #   @return [Integer]
  # @!attribute record
  #   @return [ActiveRecord::Base, nil] the record, nil in a job once it is destroyed or gone
  # @!attribute destroyed
  #   @return [Boolean]
  # @!attribute changed_attributes
  #   @return [Array<String>] the attributes the change saved; empty for a destroy, unless it was merged with an earlier save (`#merge`)
  # @!attribute previous_foreign_keys
  #   @return [Hash{String => Object}] the foreign key attributes' values before a change that moved or destroyed the
  #     record; empty otherwise
  # @!attribute previous_watcher_ids
  #   @return [Hash{String => Array}] by trigger key, the `affects:` watchers of a destroyed record, which a job
  #     cannot read once the record is gone
  Change = Struct.new(:record_class, :record_type, :record_id, :record, :destroyed, :changed_attributes, :previous_foreign_keys, :previous_watcher_ids, keyword_init: true) do
    # The change `record` just made, for `triggers`. With `resolve_affects`, reads each `affects:` trigger's watchers
    # now (`previous_watcher_ids`).
    def self.capture(record, triggers, destroyed:, resolve_affects:)
      keys = triggers.flat_map { |trigger| trigger.watches_on(record.class) }.flat_map(&:foreign_key_attributes).uniq
      moved = destroyed || keys.any? { |name| record.saved_change_to_attribute?(name) }
      new(
        record_class: record.class.base_class.name,
        record_type: record.class.name,
        record_id: record.id,
        record: record,
        destroyed: destroyed,
        changed_attributes: destroyed ? [] : record.saved_changes.keys,
        previous_foreign_keys: moved ? keys.index_with { |name| destroyed ? record[name] : record.attribute_before_last_save(name) } : {},
        previous_watcher_ids: resolve_affects ? affects_ids(record, triggers) : {}
      )
    end

    def self.affects_ids(record, triggers)
      triggers.select(&:affects).to_h do |trigger|
        [ trigger.key, Helpers.evaluate(trigger.affects, record).pluck(trigger.observing_class.primary_key) ]
      end
    end

    # The change a job reads from its payload. `previous_owner_ids` is the name a job enqueued by an earlier version
    # of Watchtower gives `previous_watcher_ids`.
    def self.from_payload(record_class:, record_id:, destroyed:, changed_attributes:, record_type: record_class, previous_foreign_keys: {}, previous_watcher_ids: {}, previous_owner_ids: {})
      previous_watcher_ids = previous_owner_ids.merge(previous_watcher_ids)
      record = record_class.constantize.find_by(id: record_id) unless destroyed
      new(
        record_class: record_class, record_type: record_type, record_id: record_id, record: record, destroyed: destroyed,
        changed_attributes: changed_attributes, previous_foreign_keys: previous_foreign_keys, previous_watcher_ids: previous_watcher_ids
      )
    end

    def to_payload
      payload = { record_class: record_class, record_id: record_id, destroyed: destroyed, changed_attributes: changed_attributes }
      payload[:record_type] = record_type if record_type != record_class
      payload[:previous_foreign_keys] = previous_foreign_keys if previous_foreign_keys.present?
      payload[:previous_watcher_ids] = previous_watcher_ids if previous_watcher_ids.present?
      payload
    end

    # This change followed by `later`, as one change: the previous foreign keys are those before this change.
    def merge(later)
      self.class.new(
        record_class: record_class,
        record_type: record_type,
        record_id: record_id,
        record: later.record,
        destroyed: destroyed || later.destroyed,
        changed_attributes: changed_attributes | later.changed_attributes,
        previous_foreign_keys: later.previous_foreign_keys.merge(previous_foreign_keys),
        previous_watcher_ids: previous_watcher_ids.merge(later.previous_watcher_ids)
      )
    end

    # The watches of `trigger` that observe the changed record's class.
    def watches_of(trigger)
      trigger.watches_on(record ? record.class : record_type.constantize)
    end
  end
end
