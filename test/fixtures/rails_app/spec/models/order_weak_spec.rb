# frozen_string_literal: true

require "rails_helper"

# WEAK spec: the RSpec twin of test/models/order_weak_test.rb. It runs every
# method but checks only shapes, so mutants survive.
RSpec.describe Order do
  it "returns plausible shapes" do
    order = orders(:bulk)
    expect(order.subtotal_cents).to be_a(Integer)
    expect(order.total_cents).to be_a(Integer)
    expect([true, false]).to include(order.free_shipping?)
  end
end
