module Watchtower
  class Observer < ::ActiveRecord::Observer
    class_attribute :triggers, default: []
    observe [] # Hack to allow the observer to initialize, we'll set the actual observable classes in reinitialize.

    def self.add_trigger(observing_class, **options)
      observing_class = Helpers.constantize(observing_class)
      triggers << build_trigger(options.merge(observing_class: observing_class))
      reinitialize unless observed_classes.include?(observing_class)
      Rails.logger.debug { "Observing #{triggers.last.class}" }
    end

    def self.build_trigger(attribute: nil, **options)
      unless options[:observing_class]
        raise ArgumentError, 'Must specify an observing class. What class is watching for changes?'
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

      if [:class].blank?
        raise ArgumentError, "Must specify which class is observed, e.g. class: MyClass"
      end
      binding.pry
      return Trigger.new(options).freeze
    end

    Trigger = Struct.new(:observing_class, :callback, :association, :attributes, :class, :affects, :includes, keyword_init: true)

    def self.reinitialize
      observe observable_classes
      instance.send(:initialize)
    end

    def self.observable_classes
      triggers.pluck(:class).uniq
    end

    def after_save(changed_record)
      Watchtower::Job.perform_later(payload_for_processing(changed_record))
    end

    private

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
