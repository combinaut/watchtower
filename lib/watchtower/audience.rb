module Watchtower
  # Used to find the records of the observing class that a change reaches through one watch of a trigger.
  class Audience
    def initialize(trigger, watch)
      @trigger = trigger
      @watch = watch
    end

    # The relations of the observing class that hold the audience.
    def scopes(change)
      [ current(change) ].compact
    end

    private

    def observing_class
      @trigger.observing_class
    end

    def reflection
      @watch.reflection
    end

    def current(change)
      return Helpers.evaluate(@trigger.affects, change.record) unless reflection

      observing_class.joins(reflection.name).where(reflection.klass.table_name => { reflection.klass.primary_key => change.record_id })
    end
  end
end
