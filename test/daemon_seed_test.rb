# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "mutineer/daemon_server"
require "mutineer/minitest_integration"

# #282: the `--daemon` mutant run uses the seed of the clean check, so each
# mutant fork runs the tests in the same order. Rails-free, so it stays in the
# default suite.
class DaemonSeedTest < Minitest::Test
  SEED_FIXTURE = File.expand_path("fixtures/stop_at_first_failure_seed_test.rb", __dir__)

  def test_daemon_mutant_run_pins_the_seed
    Dir.mktmpdir("mutineer-daemon-seed") do |dir|
      marker = File.join(dir, "seed")
      pid = fork do
        Process.setpgid(0, 0)
        Mutineer::ChildStdout.silence
        ENV.delete("SEED")
        ENV["MUTINEER_FIXTURE_MARKER"] = marker
        Mutineer::DaemonServer.instance_variable_set(:@framework, "minitest")
        exit!(Mutineer::DaemonServer.send(:run_tests, [SEED_FIXTURE]))
      rescue Exception # rubocop:disable Lint/RescueException
        exit!(2)
      end
      assert_equal 0, wait_child(pid).exitstatus
      assert_equal Mutineer::MinitestIntegration::PINNED_SEED.to_s, File.read(marker)
    end
  end
end

# The daemon runs RSpec through the runner the in-process path uses.
# Rails-free, so it stays in the default suite.
class DaemonRSpecRunTest < Minitest::Test
  FIX = File.expand_path("fixtures/rspec", __dir__)

  def daemon_run(spec)
    pid = fork do
      Process.setpgid(0, 0)
      Mutineer::ChildStdout.silence
      Mutineer::DaemonServer.instance_variable_set(:@framework, "rspec")
      exit!(Mutineer::DaemonServer.send(:run_tests, [File.join(FIX, spec)]))
    rescue Exception # rubocop:disable Lint/RescueException
      exit!(3)
    end
    wait_child(pid).exitstatus
  end

  def test_passing_spec_survives_and_failing_spec_kills
    assert_equal 0, daemon_run("passing_spec.rb")
    assert_equal 1, daemon_run("failing_spec.rb")
  end

  def test_spec_that_fails_to_load_is_an_error
    assert_equal 2, daemon_run("load_error_spec.rb")
  end

  def test_unknown_framework_raises
    Mutineer::DaemonServer.instance_variable_set(:@framework, "cucumber")
    assert_raises(RuntimeError) { Mutineer::DaemonServer.send(:run_tests, []) }
  ensure
    Mutineer::DaemonServer.instance_variable_set(:@framework, nil)
  end
end
