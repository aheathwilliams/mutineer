# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rspec/rails"
require "spec_helper"

# No migrations dir — load the schema directly, as test/test_helper.rb does.
load File.expand_path("../db/schema.rb", __dir__)

RSpec.configure do |config|
  # The same transactional fixtures as the Minitest suite: each example runs in
  # a rolled-back transaction, which per-worker databases keep apart.
  config.fixture_paths = [File.expand_path("../test/fixtures", __dir__)]
  config.use_transactional_fixtures = true
  config.global_fixtures = :all
end
