ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

# In-memory schema for the dummy models the specs exercise (Author has_many Books has_many Reviews).
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :authors, force: true do |t|
    t.string :name
    t.integer :reindex_count, default: 0, null: false
    t.timestamps
  end

  create_table :books, force: true do |t|
    t.belongs_to :author
    t.string :title
    t.timestamps
  end

  create_table :reviews, force: true do |t|
    t.belongs_to :book
    t.integer :rating
    t.timestamps
  end
end

# Jobs are enqueued, not run, unless an example opts in via perform_enqueued_jobs.
ActiveJob::Base.queue_adapter = :test

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include ActiveJob::TestHelper

  # Triggers are global state on Watchtower::Observer; each example registers its own, so snapshot and
  # restore the list (and re-derive observed classes) around every example to keep them isolated.
  config.around do |example|
    saved_triggers = Watchtower::Observer.triggers.dup
    example.run
  ensure
    Watchtower::Observer.triggers = saved_triggers
    Watchtower::Observer.reinitialize
  end
end
