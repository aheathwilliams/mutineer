# frozen_string_literal: true

require "rails_helper"

# STRONG spec: the RSpec twin of test/models/order_test.rb. It pins every
# branch and boundary, so the default operators leave no survivors.
RSpec.describe Order do
  it "multiplies quantity by unit price" do
    expect(orders(:small).subtotal_cents).to eq(2000)
    expect(orders(:bulk).subtotal_cents).to eq(50_000)
  end

  it "leaves a total below the threshold unchanged" do
    expect(orders(:small).total_cents).to eq(2000)
  end

  it "gives no discount at the threshold" do
    expect(orders(:edge).total_cents).to eq(10_000)
  end

  it "gives the bulk discount above the threshold" do
    expect(orders(:bulk).total_cents).to eq(45_000)
  end

  it "adds the rush surcharge" do
    expect(orders(:rush_small).total_cents).to eq(2500)
  end

  it "composes bulk and rush" do
    expect(orders(:bulk_rush).total_cents).to eq(45_500)
  end

  it "ships free only at the threshold and without rush" do
    expect(orders(:bulk).free_shipping?).to be(true)
    expect(orders(:edge).free_shipping?).to be(true)
    expect(orders(:small).free_shipping?).to be(false)
    expect(orders(:rush_small).free_shipping?).to be(false)
    expect(orders(:bulk_rush).free_shipping?).to be(false)
  end
end
