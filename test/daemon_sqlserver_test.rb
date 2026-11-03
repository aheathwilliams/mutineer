# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "mutineer/rails_worker_db"
require "mutineer/runner"
require "mutineer/cli"
require "open3"
require "tmpdir"

# SQL Server worker databases. Skipped unless DB=sqlserver. The CI job sets
# that and provides SQL Server 2022. These tests use the fixture app's tiny_tds client.
class DaemonSqlserverTest < Minitest::Test
  APP = File.expand_path("fixtures/rails_app", __dir__)
  ROOT = File.expand_path("..", __dir__)
  ORDER = File.join(APP, "app/models/order.rb")
  TEST_FILE = File.join(APP, "test/models/order_test.rb")
  WORKER_DB = File.expand_path("../lib/mutineer/rails_worker_db.rb", __dir__)
  BASE = ENV.fetch("MSSQL_DATABASE", "mutineer_rails_test")

  def setup
    skip "set DB=sqlserver to run SQL Server worker-database tests" unless ENV["DB"] == "sqlserver"
  end

  def config_for(jobs)
    Mutineer::Config.new(
      sources: [ORDER], tests: [TEST_FILE], project_root: APP, boot: "config/environment",
      rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: jobs
    )
  end

  def boot_config(slots: 2, role: nil)
    boot = {
      project_root: APP,
      boot: File.join(APP, "config/environment"),
      load_paths: [File.join(APP, "test")],
      source_dirs: [File.join(APP, "app/models")],
      framework: "minitest",
      rails: true,
      require_paths: [File.join(APP, "test/support/seed_setup")],
      slots: slots
    }
    boot[:db_role] = role if role
    boot
  end

  def app_env
    Mutineer::DaemonClient.new(boot: boot_config, app_root: APP).send(:app_env)
  end

  def fixture_ruby(script)
    Open3.capture2e(app_env, "bundle", "exec", "ruby", "-e", script, chdir: APP, unsetenv_others: true)
  end

  def statuses(aggregate)
    aggregate.results.map { |result| [result.id, result.status] }.sort
  end

  def test_jobs_3_worker_databases_hold_the_base_rows_during_the_run
    client = Mutineer::DaemonClient.new(boot: boot_config(slots: 3), app_root: APP).start
    names = 3.times.map { |slot| Mutineer::RailsWorkerDb.sqlserver_worker_database(BASE, slot) }
    script = <<~RUBY
      require "tiny_tds"
      conn = TinyTds::Client.new(#{connect_literal('"master"')})
      #{names.inspect}.each do |name|
        quoted = "[" + name.gsub("]", "]]") + "]"
        count = conn.execute("SELECT COUNT(*) AS c FROM \#{quoted}.dbo.seeded_rows").each.first["c"]
        puts "\#{name}=\#{count}"
      end
    RUBY
    out, status = fixture_ruby(script)
    assert status.success?, out
    names.each { |name| assert_includes out, "#{name}=1" }
  ensure
    client&.quit
  end

  def test_provision_runs_again_when_coverage_is_cached
    Dir.mktmpdir("mutineer-sqlserver-cache") do |dir|
      config = config_for(1)
      config.cache_dir = dir
      capture_subprocess_io { Mutineer::Runner.execute(config) }
      aggregate = nil
      _out, err = capture_subprocess_io { aggregate = Mutineer::Runner.execute(config).first }
      assert_equal 100.0, aggregate.mutation_score
      assert_includes err, "provisioned 1 sqlserver worker database(s) from #{BASE}"
    end
  end

  def test_jobs_4_matches_jobs_1
    serial = nil
    parallel = nil
    capture_subprocess_io do
      serial = Mutineer::Runner.execute(config_for(1)).first
      parallel = Mutineer::Runner.execute(config_for(4)).first
    end
    assert_equal statuses(serial), statuses(parallel)
    assert_equal 100.0, parallel.mutation_score
    assert_operator parallel.killed_count, :>, 0
  end

  def test_a_restarted_worker_reconnects_without_provisioning_again
    client = nil
    primer = Mutineer::DaemonClient.new(boot: boot_config(slots: 1), app_root: APP).start
    primer.quit
    client = Mutineer::DaemonClient.new(boot: boot_config(slots: 1, role: "worker"), app_root: APP).start
    pid = client.instance_variable_get(:@wait_thr).pid
    Process.kill("KILL", pid)
    code = File.read(ORDER)
    assert_equal "error", request(client, 1, code)
    assert_equal "survived", request(client, 2, code)
  ensure
    client&.quit
  end

  def test_a_second_run_stops_while_the_first_holds_the_lock
    holder = spawn_holder(<<~RUBY)
      require "./config/environment"
      require #{WORKER_DB.inspect}
      Mutineer::RailsWorkerDb.prepare_worker!
      $stdout.puts "READY"
      $stdout.flush
      sleep 180
    RUBY
    out, status = run_cli(1)
    assert_equal 1, status.exitstatus, out
    assert_includes out, "another Mutineer run is using #{BASE}"
  ensure
    stop_holder(holder)
  end

  # A mutant fork frees its copy of the lock client at its next GC. That must
  # not end the parent's session, or a second run could drop live databases.
  def test_the_lock_survives_a_fork_child_that_frees_its_copy
    holder = spawn_holder(<<~RUBY)
      require "./config/environment"
      require #{WORKER_DB.inspect}
      Mutineer::RailsWorkerDb.prepare_worker!
      child = fork do
        Mutineer::RailsWorkerDb.forget_lock_connection_after_fork!
        3.times { Array.new(100_000) { "x" * 10 } && GC.start(full_mark: true, immediate_sweep: true) }
        exit!(0)
      end
      Process.wait(child)
      $stdout.puts "READY"
      $stdout.flush
      sleep 180
    RUBY
    out, status = run_cli(1)
    assert_equal 1, status.exitstatus, out
    assert_includes out, "another Mutineer run is using #{BASE}"
  ensure
    stop_holder(holder)
  end

  def test_a_killed_run_does_not_block_the_next_run
    holder = spawn_holder(<<~RUBY)
      require "./config/environment"
      require #{WORKER_DB.inspect}
      Mutineer::RailsWorkerDb.provision(2)
      $stdout.puts "READY"
      $stdout.flush
      sleep 180
    RUBY
    stop_holder(holder, signal: "KILL")
    holder = nil
    aggregate = nil
    capture_subprocess_io { aggregate = Mutineer::Runner.execute(config_for(1)).first }
    assert_equal 100.0, aggregate.mutation_score
  ensure
    stop_holder(holder)
  end

  # A restore copies what a table-by-table copy can lose: the identity seed,
  # foreign keys, and triggers, which must not fire on the copied rows. A
  # session left open on an old slot must not stop the next copy.
  def test_restore_keeps_identity_keys_and_triggers_and_replaces_a_busy_slot
    script = <<~RUBY
      require "./config/environment"
      require "tiny_tds"
      require #{WORKER_DB.inspect}
      conn = TinyTds::Client.new(#{connect_literal(BASE.inspect)})
      run = ->(c, sql) { c.execute(sql).do }
      rows = ->(c, sql) { c.execute(sql).each.map { |r| r.values.join(":") }.join(",") }
      begin
        run.(conn, "IF OBJECT_ID('dbo.kids') IS NOT NULL DROP TABLE dbo.kids")
        run.(conn, "IF OBJECT_ID('dbo.kid_audits') IS NOT NULL DROP TABLE dbo.kid_audits")
        run.(conn, "IF OBJECT_ID('dbo.parents') IS NOT NULL DROP TABLE dbo.parents")
        run.(conn, "CREATE TABLE dbo.parents (id int IDENTITY(1,1) PRIMARY KEY, name nvarchar(20) NOT NULL)")
        run.(conn, "CREATE TABLE dbo.kids (id int IDENTITY(1,1) PRIMARY KEY, parent_id int NOT NULL REFERENCES dbo.parents(id))")
        run.(conn, "CREATE TABLE dbo.kid_audits (id int IDENTITY(1,1) PRIMARY KEY, kid_id int NOT NULL)")
        run.(conn, "CREATE TRIGGER dbo.kids_audit ON dbo.kids AFTER INSERT AS INSERT INTO dbo.kid_audits (kid_id) SELECT id FROM inserted")
        run.(conn, "INSERT INTO dbo.parents (name) VALUES (N'a'), (N'b'), (N'c')")
        run.(conn, "DELETE FROM dbo.parents WHERE name = N'c'")
        run.(conn, "INSERT INTO dbo.kids (parent_id) VALUES (1)")
        Mutineer::RailsWorkerDb.provision(1)
        name = Mutineer::RailsWorkerDb.sqlserver_worker_database(#{BASE.inspect}, 0)
        busy = TinyTds::Client.new(#{connect_literal('name')})
        # End the first run: closing its session releases the shared lock.
        Mutineer::RailsWorkerDb.instance_variable_get(:@lock_connection).close
        Mutineer::RailsWorkerDb.instance_variable_set(:@lock_connection, nil)
        Mutineer::RailsWorkerDb.provision(1)
        slot = TinyTds::Client.new(#{connect_literal('name')})
        run.(slot, "INSERT INTO dbo.parents (name) VALUES (N'd')")
        puts "next_id=\#{rows.(slot, "SELECT MAX(id) FROM dbo.parents")}"
        puts "audits=\#{rows.(slot, "SELECT kid_id FROM dbo.kid_audits ORDER BY id")}"
        run.(slot, "INSERT INTO dbo.kids (parent_id) VALUES (2)")
        puts "audits_after=\#{rows.(slot, "SELECT kid_id FROM dbo.kid_audits ORDER BY id")}"
        fk = begin
          run.(slot, "INSERT INTO dbo.kids (parent_id) VALUES (99)")
          "missing"
        rescue TinyTds::Error
          "enforced"
        end
        puts "fk=\#{fk}"
        busy_closed = begin
          busy.execute("SELECT 1 AS one").each
          false
        rescue TinyTds::Error
          true
        end
        puts "busy_closed=\#{busy_closed}"
      ensure
        run.(conn, "IF OBJECT_ID('dbo.kids') IS NOT NULL DROP TABLE dbo.kids")
        run.(conn, "IF OBJECT_ID('dbo.kid_audits') IS NOT NULL DROP TABLE dbo.kid_audits")
        run.(conn, "IF OBJECT_ID('dbo.parents') IS NOT NULL DROP TABLE dbo.parents")
      end
    RUBY
    out, status = fixture_ruby(script)
    assert status.success?, out
    assert_includes out, "next_id=4", out
    assert_includes out, "audits=1\n", out
    assert_includes out, "audits_after=1,2\n", out
    assert_includes out, "fk=enforced", out
    assert_includes out, "busy_closed=true", out
  end

  private

  def request(client, id, code)
    client.request(id: id, worker: 0, timeout: 60,
                   payload: { "code" => code, "source_file" => ORDER }, tests: [TEST_FILE])
  end

  # Keyword arguments for TinyTds::Client.new. `database_expr` is Ruby source.
  def connect_literal(database_expr)
    [
      "host: #{ENV.fetch('MSSQL_HOST', '127.0.0.1').inspect}",
      "port: #{Integer(ENV.fetch('MSSQL_PORT', '1433'))}",
      "username: #{ENV.fetch('MSSQL_USER', 'sa').inspect}",
      "password: ENV.fetch(\"MSSQL_SA_PASSWORD\")",
      "database: #{database_expr}"
    ].join(", ")
  end

  def spawn_holder(script)
    read, write = IO.pipe
    pid = spawn(app_env, "bundle", "exec", "ruby", "-e", script,
                chdir: APP, unsetenv_others: true, out: write, pgroup: true)
    write.close
    line = read.gets
    read.close
    flunk("holder did not start: #{line.inspect}") unless line&.start_with?("READY")
    pid
  end

  def stop_holder(pid, signal: "TERM")
    return unless pid

    Process.kill(signal, -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
    nil
  end

  def run_cli(jobs)
    script = <<~RUBY
      require "mutineer"
      config = Mutineer::Config.new(
        sources: [#{ORDER.inspect}],
        tests: [#{TEST_FILE.inspect}],
        project_root: #{APP.inspect},
        boot: "config/environment",
        rails: true, daemon: true, strategy: "reload", framework: "minitest", jobs: #{jobs}
      )
      Mutineer::CLI.run(config)
    RUBY
    Open3.capture2e(ENV.to_h, "bundle", "exec", "ruby", "-Ilib", "-e", script, chdir: ROOT)
  end
end
