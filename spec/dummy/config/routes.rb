Rails.application.routes.draw do
  mount Watchtower::Engine => "/watchtower"
end
