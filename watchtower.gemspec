require_relative "lib/watchtower/version"

Gem::Specification.new do |spec|
  spec.name        = "watchtower"
  spec.version     = Watchtower::VERSION
  spec.authors     = [ "Nicholas Jakobsen" ]
  spec.email       = [ "nicholas@combinaut.com" ]
  # spec.homepage    = "TODO"
  spec.summary     = "Allows your model to execute callbacks in response to changes on related records"
  # spec.description = "TODO: Description of Watchtower."
  spec.license     = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the "allowed_push_host"
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

  # spec.metadata["homepage_uri"] = spec.homepage
  # spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here."
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.required_ruby_version = ">= 2.7"
  spec.add_dependency "rails", ">= 5.2", "< 8.0"
  spec.add_dependency "rails-observers"
  spec.add_development_dependency "appraisal"
end
