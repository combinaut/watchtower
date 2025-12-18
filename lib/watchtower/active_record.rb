module Watchtower
  module ActiveRecord
    extend ActiveSupport::Concern

    class_methods do
      # on_related_record_change :update_finder_score, class: 'ProviderNetwork', association: :provider_networks, attribute: :provider_boost_amount, includes: INCLUDES_FOR_FINDER_SCORE # We need to specify the class because we're calling this before the association has been defined
      # watches :provider_networks, attribute: :provider_boost_amount, callback: :update_finder_score, class: 'ProviderNetwork', includes: INCLUDES_FOR_FINDER_SCORE # We need to specify the class because we're calling this before the association has been defined
      def watches(**options)
        Watchtower::Observer.add_trigger(self, **options)
      end
    end
  end
end
