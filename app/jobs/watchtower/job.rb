module Watchtower
  class Job < Watchtower::ApplicationJob
    self.queue_adapter = :async if Rails.env.development? # Don't force Delayed Job to run just for indexing a single record in dev mode

    def perform(record_class:, record_id:, destroyed:, changed_attributes:)
      changed_record = record_class.constantize.find(record_id)
      changed_attributes = changed_attributes.map(&:to_sym)
      triggers_for_class(record_class).each do |trigger|
        next unless trigger_relevant?(trigger, record_class: record_class, record_id: record_id, destroyed: destroyed, changed_attributes: changed_attributes)
        process_trigger(trigger, changed_record)
      end
    end

    private

    def process_trigger(trigger, changed_record)
      audience_for_change(trigger, changed_record).includes(trigger.includes).find_each do |observing_record|
        execute_callback(trigger.callback, observing_record)
        Rails.logger.debug { "Executed #{self.class} callback for #{observing_record.class} #{observing_record.id}: #{trigger.callback}" }
      end
    end

    def triggers_for_class(klass)
      klass = Helpers.constantize(klass)
      Watchtower::Observer.triggers.select do |trigger|
        klass <= trigger.class
      end
    end

    def trigger_relevant?(trigger, record_class:, record_id:, destroyed:, changed_attributes:)
      Rails.logger.debug { "Change to #{record_class} #{record_id} was relevant to a trigger on #{trigger.observing_class} because the record was changed" } and return true unless trigger.attributes.present?
      Rails.logger.debug { "Destruction of #{record_class} #{record_id} was relevant to a trigger on #{trigger.observing_class} because the record was destroyed" } and return true if destroyed
      Rails.logger.debug { "Change to #{changed_attributes.to_sentence} on #{record_class} #{record_id} was relevant to a trigger on #{trigger.observing_class} because an observed attribute was changed" } and return true if Set.new(trigger.attributes).intersect?(Set.new(changed_attributes))
      Rails.logger.debug { "Change to #{record_class} #{record_id} was not relevant to a trigger on #{trigger.observing_class}" } and return false
    end

    def audience_for_change(trigger, changed_record)
      if trigger.association # All records from the observing class whose trigger association include the changed record
        table_name = trigger.observing_class.reflect_on_association(trigger.association).table_name
        trigger.observing_class.joins(trigger.association).where(table_name => { id: changed_record }).distinct
      elsif trigger.affects # All records from the scope returned by the trigger `affects` callback
        execute_callback(trigger.affects, changed_record)
      else
        binding.pry
        raise "No audience for trigger on #{trigger.observing_class}: #{trigger.callback}"
      end
    end

    def execute_callback(callback, receiver)
      case callback
      when Proc
        callback.arity > 0 ? callback.call(receiver) : callback.call
      when Symbol, String
        receiver.send(callback)
      else
        raise "Unhandled callback #{callback.inspect}"
      end
    end
  end
end
