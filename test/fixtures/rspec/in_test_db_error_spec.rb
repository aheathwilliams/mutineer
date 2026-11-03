# frozen_string_literal: true

# Stand-ins for the Active Record error classes (#347), as in
# test/fixtures/in_test_db_error_test.rb. Only ever loaded in a forked child.
module ActiveRecord
  class StatementInvalid < StandardError; end
  class ConnectionNotEstablished < StandardError; end
  class ConnectionNotDefined < ConnectionNotEstablished; end
  class TransactionRollbackError < StatementInvalid; end
  class Deadlocked < TransactionRollbackError; end
end

# MUTINEER_FIXTURE_FIRST and MUTINEER_FIXTURE_SECOND set each example: pass
# (the default), fail, or the name of an error to raise.
RSpec.describe "in-test database error" do
  errors = {
    "connection" => ActiveRecord::ConnectionNotEstablished,
    "connection_not_defined" => ActiveRecord::ConnectionNotDefined,
    "deadlock" => ActiveRecord::Deadlocked,
    "statement_invalid" => ActiveRecord::StatementInvalid,
    "runtime" => RuntimeError
  }

  act = lambda do |what|
    case what
    when "pass" then nil
    when "fail" then expect(1).to eq(2)
    else raise errors.fetch(what), "server at postgres://user:secret@db/x closed the connection"
    end
  end

  it("a first") { instance_exec(ENV.fetch("MUTINEER_FIXTURE_FIRST", "pass"), &act) }
  it("b second") { instance_exec(ENV.fetch("MUTINEER_FIXTURE_SECOND", "pass"), &act) }
end
