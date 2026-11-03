# frozen_string_literal: true

# Framework-only settings. Mutineer finds the spec load root by this file.
RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
