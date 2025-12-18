module Watchtower
  class Engine < ::Rails::Engine
    isolate_namespace Watchtower

    initializer "watchtower.active_record" do
      ActiveSupport.on_load(:active_record) do
        include Watchtower::ActiveRecord
      end
    end

    initializer "watchtower.active_record.observers", after: :load_config_initializers do |app|
      app.config.active_record.observers ||= []
      app.config.active_record.observers << 'Watchtower::Observer'
    end
  end
end
