# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/config"
require "mutineer/runner"

# RSpec on the daemon path: the RSpec twin of RunnerDaemonParallelTest. Each
# daemon worker runs the fixture app's spec/ suite against its own database,
# and --jobs 2 must give the verdicts of --jobs 1. The strong and weak specs
# mirror test/models/order_test.rb and order_weak_test.rb, so the scores must
# also match the Minitest suite's.
class RunnerDaemonRSpecTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)

  def config_for(spec_file, jobs, framework: "rspec", tests_dir: "spec")
    Mutineer::Config.new(
      sources: [File.join(APP, "app/models/order.rb")],
      tests: [File.join(APP, tests_dir, "models", spec_file)],
      project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload",
      framework: framework, jobs: jobs
    )
  end

  # Order-independent outcome identity: parallel finish order must not change it.
  def identity(aggregate)
    {
      score: aggregate.mutation_score,
      killed: aggregate.killed_count,
      survivors: aggregate.surviving_mutants.map(&:id).sort
    }
  end

  def execute(config)
    result = nil
    capture_io { result, = Mutineer::Runner.execute(config) }
    result
  end

  def assert_parallel_matches_serial(spec_file)
    serial = execute(config_for(spec_file, 1))
    parallel = execute(config_for(spec_file, 2))
    assert_equal identity(serial), identity(parallel),
                 "--jobs 2 must equal --jobs 1 (score/kills/survivors) on #{spec_file}"
    assert_equal 0, parallel.errored_count, "no mutant may error on the RSpec daemon path"
    [serial, parallel]
  end

  def test_strong_spec_jobs2_equals_jobs1_and_scores_100
    serial, parallel = assert_parallel_matches_serial("order_spec.rb")
    assert_equal 100.0, parallel.mutation_score
    assert_empty parallel.surviving_mutants, "strong spec leaves no survivors under --jobs 2"
    assert_operator serial.killed_count, :>, 0
  end

  def test_weak_spec_jobs2_equals_jobs1_with_real_survivors
    _serial, parallel = assert_parallel_matches_serial("order_weak_spec.rb")
    refute_empty parallel.surviving_mutants, "weak spec should still leave survivors under --jobs 2"
    assert_operator parallel.mutation_score, :<, 100.0
  end

  # The specs are twins of the Minitest tests, so both frameworks must score
  # the same mutants the same way on the daemon.
  def test_weak_spec_matches_the_minitest_weak_suite
    rspec = execute(config_for("order_weak_spec.rb", 2))
    minitest = execute(config_for("order_weak_test.rb", 2, framework: "minitest", tests_dir: "test"))
    assert_equal identity(minitest), identity(rspec)
  end
end
