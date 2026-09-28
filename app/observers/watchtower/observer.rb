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
      watch = Watch.new(
        klass: options[:class], reflection: reflection, observing_class: options[:observing_class], association: options[:association],
        attributes: options[:attributes]
      )
      options[:watches] = [ watch.freeze ]
      Trigger.new(options).freeze
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
    #   @return [Array<Symbol, String>] the attributes whose change fires the trigger; empty for any change
    Watch = Struct.new(:klass, :reflection, :observing_class, :association, :attributes, keyword_init: true) do
      def reflection
        self[:reflection] || (association && observing_class.reflect_on_association(association))
      end
    end

    def self.reinitialize
      observe observable_classes
      instance.send(:initialize)
    end

    def self.observable_classes
      triggers.flat_map { |trigger| trigger.watches.map(&:klass) }.uniq
    end

    def after_save(changed_record)
      triggers = triggers_for(changed_record.class)
      enqueue(triggers, changed_record) if triggers.any?
    end

    private

    # Evaluates each matching trigger's `enabled` predicate in the saving thread, where
    # any caller-set context — e.g. a thread-local opened around an importer — is still live, then
    # carries the decision into the job as the suppressed triggers' keys. Enqueues nothing when every
    # matching trigger is suppressed.
    def enqueue(triggers, changed_record)
      suppressed = triggers.reject { |trigger| trigger_enabled?(trigger, changed_record) }
      return if suppressed.length == triggers.length

      payload = Change.capture(changed_record).to_payload
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
