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

    Trigger = Struct.new(:observing_class, :callback, :association, :attributes, :class, :affects, :includes, :enabled, :inline, :around, :watches, keyword_init: true) do
      # Stable, serialisable identity for a trigger. Lets an enable/disable decision made at enqueue
      # time (see Observer#enqueue) be carried in the job payload and matched back to this trigger
      # when the asynchronous Watchtower::Job runs (see Job#trigger_suppressed?).
      def key
        [ observing_class.name, callback, association ].join("/")
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

    # Runs the inline triggers enabled at the commit on the change the record committed: every save and destroy of
    # it in the transaction, merged into one that keeps the foreign keys from before the first save, leaving out
    # those a savepoint rolled back.
    def after_commit(changed_record)
      return unless changed_record.instance_variable_defined?(:@watchtower_changes)

      changes = changed_record.remove_instance_variable(:@watchtower_changes)
      change = changes.reject { |transaction, _| discarded?(transaction) }.map(&:last).reduce(:merge)
      return unless change

      triggers = triggers_for(changed_record.class).select(&:inline).select { |trigger| trigger_enabled?(trigger, changed_record) }
      Dispatch.run(triggers, change)
    end

    # Forgets the changes the rolled-back transaction or savepoint made, keeping those of an enclosing transaction,
    # which may still commit.
    def after_rollback(changed_record)
      return unless changed_record.instance_variable_defined?(:@watchtower_changes)

      kept = changed_record.instance_variable_get(:@watchtower_changes).reject { |transaction, _| discarded?(transaction) }
      if kept.empty?
        changed_record.remove_instance_variable(:@watchtower_changes)
      else
        changed_record.instance_variable_set(:@watchtower_changes, kept)
      end
    end

    private

    def observe_change(changed_record, destroyed:)
      triggers = triggers_for(changed_record.class)
      inline, queued = triggers.partition(&:inline)
      enqueue(queued, changed_record, destroyed: destroyed) if queued.any?
      remember_for_commit(inline, changed_record, destroyed: destroyed) if inline.any?
    end

    # Evaluates each matching trigger's `enabled` predicate in the saving thread, where
    # any caller-set context — e.g. a thread-local opened around an importer — is still live, then
    # carries the decision into the job as the suppressed triggers' keys. Enqueues nothing when every
    # matching trigger is suppressed.
    def enqueue(triggers, changed_record, destroyed:)
      suppressed = triggers.reject { |trigger| trigger_enabled?(trigger, changed_record) }
      return if suppressed.length == triggers.length

      payload = Change.capture(changed_record, triggers - suppressed, destroyed: destroyed, resolve_affects: destroyed).to_payload
      payload[:suppressed_trigger_keys] = suppressed.map(&:key) if suppressed.any?
      Watchtower::Job.perform_later(**payload)
    end

    # Stores the change on the record for `after_commit`, beside the transaction or savepoint that made it, so a
    # savepoint that rolls back takes only its own changes with it. They are kept on the record because an
    # `after_commit` is given only the record.
    def remember_for_commit(triggers, changed_record, destroyed:)
      change = Change.capture(changed_record, triggers, destroyed: destroyed, resolve_affects: false)
      changes = changed_record.instance_variable_defined?(:@watchtower_changes) ? changed_record.instance_variable_get(:@watchtower_changes) : []
      changed_record.instance_variable_set(:@watchtower_changes, changes + [ [ changed_record.class.connection.current_transaction, change ] ])
    end

    # Whether `transaction` rolled back, on its own or with a transaction enclosing it, or was invalidated by a
    # connection failure at commit.
    def discarded?(transaction)
      transaction.state.rolledback? || transaction.state.invalidated?
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
