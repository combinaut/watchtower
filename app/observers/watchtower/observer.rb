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

    Trigger = Struct.new(:observing_class, :callback, :association, :attributes, :class, :affects, :includes, :enabled, :watches, keyword_init: true) do
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

    private

    def observe_change(changed_record, destroyed:)
      triggers = triggers_for(changed_record.class)
      enqueue(triggers, changed_record, destroyed: destroyed) if triggers.any?
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

    def triggers_for(klass)
      Watchtower::Observer.triggers.select { |trigger| trigger.watches_on(klass).any? }
    end

    # A trigger with no `enabled` predicate is always enabled (existing triggers are unaffected).
    def trigger_enabled?(trigger, changed_record)
      trigger.enabled.nil? || Helpers.evaluate(trigger.enabled, changed_record)
    end
  end
end
