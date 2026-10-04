module Watchtower
  class Observer < ::ActiveRecord::Observer
    class_attribute :triggers, default: []
    observe [] # Hack to allow the observer to initialize, we'll set the actual observable classes in reinitialize.

    def self.add_trigger(observing_class, **options)
      observing_class = Helpers.constantize(observing_class)
      triggers << build_trigger(**options.merge(observing_class: observing_class))
      reinitialize unless (triggers.last.watches.map(&:klass) - observed_classes).empty?
      Rails.logger.debug { "Observing #{triggers.last.class}" }
    end

    def self.build_trigger(attribute: nil, **options)
      unless options[:observing_class]
        raise ArgumentError, "Must specify an observing class. What class is watching for changes?"
      end

      # Alias `attributes` to `attribute` and ensure it is always an array
      options[:attributes] ||= attribute
      options[:attributes] = Array.wrap(options[:attributes])

      # Introspect to populate the class option if it is blank
      if options[:class].blank?
        if options[:association]
          reflection = options[:observing_class].reflect_on_association(options[:association])
          raise ArgumentError, "Unknown association #{options[:association]} for #{options[:observing_class]}" unless reflection
          options[:class] ||= reflection.klass
        end
      else
        options[:class] = Helpers.constantize(options[:class])
      end

      if [ :class ].blank?
        raise ArgumentError, "Must specify which class is observed, e.g. class: MyClass"
      end

      options[:at] = :commit if options[:at].nil?
      options[:at] = options[:at].to_sym if options[:at].respond_to?(:to_sym)
      raise ArgumentError, "at: must be one of #{FIRING_POINTS.inspect}, got #{options[:at].inspect}" unless FIRING_POINTS.include?(options[:at])
      if options[:at] == :save && !options[:inline] && Watchtower::Job.enqueued_after_commit?
        raise ArgumentError, "at: :save cannot enqueue its job inside the transaction while Active Job defers " \
                             "Watchtower::Job's enqueue until after the commit (enqueue_after_transaction_commit)"
      end

      reflection = options[:observing_class].reflect_on_association(options[:association]) if options[:association]
      options[:watches] =
        if reflection
          watches_for(reflection, options[:attributes], foreign_keys_only: false)
        else
          watch = Watch.new(
            klass: options[:class], observing_class: options[:observing_class], association: options[:association],
            attributes: options[:attributes], foreign_keys_only: false
          )
          [ watch.freeze ]
        end
      Trigger.new(options).freeze
    end

    # The watches for `reflection`: its own class, and for an association through another, a `foreign_keys_only`
    # watch on the record it passes through, repeated for each level of nesting.
    def self.watches_for(reflection, attributes, foreign_keys_only:)
      watch = Watch.new(klass: reflection.klass, reflection: reflection, attributes: attributes, foreign_keys_only: foreign_keys_only).freeze
      return [ watch ] unless reflection.through_reflection?

      [ watch, *watches_for(reflection.through_reflection, source_foreign_key_attributes(reflection), foreign_keys_only: true) ]
    end

    # The foreign keys the record a through association passes through holds toward the association's records:
    # `has_many :reviews, through: :books` has none, `has_many :publishers, through: :books` has the `Book`'s
    # `publisher_id`, and a polymorphic source adds its `foreign_type`.
    def self.source_foreign_key_attributes(reflection)
      source = reflection.source_reflection
      return [] unless source.belongs_to? && !source.through_reflection?

      [ source.foreign_key, (source.foreign_type if source.polymorphic?) ].compact
    end

    # FIRING_POINTS are the moments a trigger can fire, its `at:`:
    #   - commit:  once the transaction that made the change commits, once for each record it changed
    #   - save:    as the record is saved or destroyed, inside its transaction, once per save or destroy
    FIRING_POINTS = %i[commit save].freeze

    Trigger = Struct.new(:observing_class, :callback, :association, :attributes, :class, :affects, :includes, :enabled, :inline, :around, :at, :watches, keyword_init: true) do
      # Stable, serialisable identity for a trigger. Lets an enable/disable decision made at enqueue
      # time (see Observer#enqueue) be carried in the job payload and matched back to this trigger
      # when the asynchronous Watchtower::Job runs (see Job#trigger_suppressed?). Two triggers on the
      # same association with the same callback keep distinct keys when their attributes, `enabled:`,
      # `around:` or `at:` differ, and a `Proc` is named by where it is defined, which every process that
      # loaded the code agrees on: `"Author/reindex!/books/title/enabled:app/models/author.rb:12"`.
      def key
        distinctions = [
          attributes.presence&.join(","),
          (enabled && "enabled:#{Trigger.identity(enabled)}"),
          (around && "around:#{Trigger.identity(around)}"),
          ("at:save" if at == :save)
        ]
        [ observing_class.name, Trigger.identity(callback), association, *distinctions.compact ].join("/")
      end

      # A `Proc` by the file, relative to the application's root, and line it is defined on; anything else by its
      # string.
      def self.identity(value)
        return value.to_s unless value.is_a?(Proc)

        file, line = value.source_location
        "#{file.delete_prefix("#{Rails.root}/")}:#{line}"
      end

      # The watches through which a change to a `klass` record reaches this trigger.
      def watches_on(klass)
        watches.select { |watch| klass <= watch.klass }
      end

      # Whether the trigger was built before its association was defined, so it watches only `class:` and not the
      # records an association through another passes through.
      def awaiting_association?
        association.present? && watches.first[:reflection].nil?
      end
    end

    # One class a trigger observes, and how a change to one of its records reaches the trigger's audience.
    #
    # @!attribute klass
    #   @return [Class] the observed class
    # @!attribute reflection
    #   @return [ActiveRecord::Reflection, nil] the observing class's association to `klass`; nil for `affects:`. For
    #     a trigger declared before its association, looked up on each read, and nil until the association exists.
    # @!attribute observing_class
    #   @return [Class] the class that declared the trigger
    # @!attribute association
    #   @return [Symbol, nil] the name of `reflection`
    # @!attribute attributes
    #   @return [Array<Symbol, String>] the attributes whose change fires the trigger. Empty means any change fires
    #     it, or, with `foreign_keys_only`, only a change to `foreign_key_attributes`.
    # @!attribute foreign_keys_only
    #   @return [Boolean] whether only a destroy, or a change to `attributes` or `foreign_key_attributes`, fires the
    #     trigger, as for a record an association passes through
    Watch = Struct.new(:klass, :reflection, :observing_class, :association, :attributes, :foreign_keys_only, keyword_init: true) do
      def reflection
        self[:reflection] || (association && observing_class.reflect_on_association(association))
      end

      # The association whose `foreign_key` the watched record holds, pointing at the record the audience is found
      # through, or nil when the watched record holds no such key.
      def foreign_key_reflection
        return nil unless reflection

        key_reflection = reflection.through_reflection? ? reflection.source_reflection : reflection
        key_reflection unless key_reflection.through_reflection? || key_reflection.belongs_to?
      end

      # The `foreign_key`, and for a polymorphic association the `foreign_type`, that `foreign_key_reflection` reads
      # from the watched record.
      def foreign_key_attributes
        key_reflection = foreign_key_reflection
        key_reflection ? [ key_reflection.foreign_key.to_s, key_reflection.type&.to_s ].compact : []
      end
    end

    # Observes every class the triggers watch, first rebuilding each trigger still awaiting its association
    # (`Trigger#awaiting_association?`), so one whose association now exists also watches the records it passes
    # through.
    def self.reinitialize
      self.triggers = triggers.map { |trigger| trigger.awaiting_association? ? build_trigger(**trigger.to_h.except(:watches)) : trigger }
      observe observable_classes
      instance.send(:initialize)
    end

    def self.observable_classes
      triggers.flat_map { |trigger| trigger.watches.map(&:klass) }.uniq
    end

    def after_save(changed_record)
      observe_change(changed_record, destroyed: false)
    end

    def after_destroy(changed_record)
      observe_change(changed_record, destroyed: true)
    end

    private

    # Fires the `at: :save` triggers on the change now, and holds it for the `at: :commit` ones until the transaction
    # it was made in commits (`hold_for_commit`). The change is captured before anything fires, so nothing a save-time
    # trigger does to the record alters what the commit-time ones fire on.
    def observe_change(changed_record, destroyed:)
      triggers = triggers_for(changed_record.class)
      return if triggers.empty?

      change = Change.capture(changed_record, triggers, destroyed: destroyed, resolve_affects: destroyed)
      hold_for_commit(changed_record, change) if triggers.any? { |trigger| trigger.at == :commit }
      fire(triggers, :save, changed_record, change) if triggers.any? { |trigger| trigger.at == :save }
    end

    # Holds `change` among the changes awaiting a commit on the record's connection, and has the transaction it was
    # made in flush them when it commits (`flush`), or drop it when it, or the savepoint it was made in, rolls back.
    # Rails runs a transaction's `after_commit` blocks once its outermost transaction commits, and passes a released
    # savepoint's blocks to the transaction around it.
    def hold_for_commit(changed_record, change)
      connection = changed_record.class.connection
      held = held_changes(connection)
      key = [ changed_record.class.base_class.name, changed_record.id ]
      entry = [ changed_record, change ]
      (held[key] ||= []) << entry

      transaction = changed_record.class.current_transaction
      transaction.after_rollback do
        held[key]&.delete_if { |held_entry| held_entry.equal?(entry) }
        held.delete(key) if held[key]&.empty?
      end
      transaction.after_commit { flush(connection) }
    end

    # Fires the `at: :commit` triggers once for each row the held changes touch, on that row's changes merged into
    # one: every attribute they changed, and the owners the row had before the earliest of them (`Change#merge`).
    # Each predicate is read against the instance the row was last saved through. The held changes are taken before
    # anything fires, so a change a callback makes is held for its own transaction's commit. Every save in a
    # transaction registers a flush, and the first to run takes every held change, so the rest find none.
    def flush(connection)
      held = held_changes(connection)
      return if held.empty?

      connection.instance_variable_set(:@watchtower_held_changes, {})
      held.each_value do |entries|
        next if entries.empty?

        changed_record = entries.last.first
        fire(triggers_for(changed_record.class), :commit, changed_record, entries.map(&:last).reduce(:merge))
      end
    end

    # The changes awaiting a commit on `connection`, `{ [base class name, id] => [[record, change], ...] }` in the
    # order they were saved.
    def held_changes(connection)
      connection.instance_variable_get(:@watchtower_held_changes) || connection.instance_variable_set(:@watchtower_held_changes, {})
    end

    # Fires `change` for the `triggers` that fire `at`, in this thread, reading each one's `enabled` predicate now,
    # while any caller-set context, such as a thread-local set around a block of writes, is still live. The enabled
    # inline triggers run here, and the enabled queued ones run in one `Watchtower::Job`.
    def fire(triggers, at, changed_record, change)
      inline, queued = triggers.partition(&:inline)
      Dispatch.run(inline.select { |trigger| trigger.at == at && trigger_enabled?(trigger, changed_record) }, change)
      enqueue(queued, at, changed_record, change)
    end

    # Queues `change` for the `queued` triggers that fire `at` and are enabled. The job runs the queued triggers that
    # fire `at` and that the change reaches, except those whose keys it carries as suppressed: the ones disabled now.
    # Enqueues nothing when none of them is enabled.
    def enqueue(queued, at, changed_record, change)
      firing = queued.select { |trigger| trigger.at == at }
      enabled = firing.select { |trigger| trigger_enabled?(trigger, changed_record) }
      return if enabled.empty?

      suppressed = firing - enabled
      payload = change.to_payload.merge(at: at)
      payload[:suppressed_trigger_keys] = suppressed.map(&:key) if suppressed.any?
      Watchtower::Job.perform_later(**payload)
    end

    def triggers_for(klass)
      Watchtower::Observer.triggers.select { |trigger| trigger.watches_on(klass).any? }
    end

    # A trigger with no `enabled` predicate is always enabled (existing triggers are unaffected).
    def trigger_enabled?(trigger, changed_record)
      trigger.enabled.nil? || Helpers.evaluate(trigger.enabled, changed_record)
    end
  end
end
