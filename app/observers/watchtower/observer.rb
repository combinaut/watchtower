module Watchtower
  class Observer < ::ActiveRecord::Observer
    class_attribute :triggers, default: []
    observe [] # Hack to allow the observer to initialize, we'll set the actual observable classes in reinitialize.

    def self.add_trigger(observing_class, **options)
      observing_class = Helpers.constantize(observing_class)
      triggers << build_trigger(**options.merge(observing_class: observing_class))
      reinitialize unless observed_classes.include?(observing_class)
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

      Trigger.new(options).freeze
    end

    Trigger = Struct.new(:observing_class, :callback, :association, :attributes, :class, :affects, :includes, :enabled, keyword_init: true) do
      # Stable, serialisable identity for a trigger. Lets an enable/disable decision made at enqueue
      # time (see Observer#after_save) be carried in the job payload and matched back to this trigger
      # when the asynchronous Watchtower::Job runs (see Job#trigger_suppressed?).
      def key
        [ observing_class.name, callback, association ].join("/")
      end
    end

    def self.reinitialize
      observe observable_classes
      instance.send(:initialize)
    end

    def self.observable_classes
      triggers.pluck(:class).uniq
    end

    # Evaluate each matching trigger's `enabled` predicate INLINE (here, in the saving thread, where
    # any caller-set context — e.g. a thread-local opened around an importer — is still live), then
    # carry the decision into the async job by recording the suppressed triggers' keys. If every
    # matching trigger is suppressed there is nothing for the job to do, so we skip enqueuing entirely.
    def after_save(changed_record)
      triggers = triggers_for(changed_record.class)
      suppressed = triggers.reject { |trigger| trigger_enabled?(trigger, changed_record) }
      return if triggers.any? && suppressed.length == triggers.length

      payload = payload_for_processing(changed_record)
      payload[:suppressed_trigger_keys] = suppressed.map(&:key) if suppressed.any?
      Watchtower::Job.perform_later(**payload)
    end

    private

    def triggers_for(klass)
      Watchtower::Observer.triggers.select { |trigger| klass <= trigger.class }
    end

    # A trigger with no `enabled` predicate is always enabled (existing triggers are unaffected).
    def trigger_enabled?(trigger, changed_record)
      trigger.enabled.nil? || Helpers.evaluate(trigger.enabled, changed_record)
    end

    def payload_for_processing(changed_record)
      {
        record_class: changed_record.class.base_class.name,
        record_id: changed_record.id,
        destroyed: changed_record.destroyed?,
        changed_attributes: changed_record.saved_changes.keys
      }
    end
  end
end
