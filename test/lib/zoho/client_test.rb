require "test_helper"

class Zoho::ClientTest < ActiveSupport::TestCase
  setup do
    @client = Zoho::Client.new(client_id: "id", client_secret: "secret", refresh_token: "token")
  end

  # Regression: Zoho's search endpoint returns only approved, unconverted records
  # unless told otherwise, which silently hides web-form leads awaiting approval.
  test "search_all_records sweeps every approval state and de-duplicates" do
    seen = []
    @client.define_singleton_method(:search_records) do |_module, criteria:, fields: nil, converted: nil, approval_state: nil|
      seen << [ converted, approval_state ]
      approval_state == "webform_unapproved" ? [ { "id" => "unapproved" } ] : [ { "id" => "approved" } ]
    end

    records = @client.search_all_records("Leads", criteria: "(Email:equals:a@b.c)")

    assert_equal Zoho::Client::APPROVAL_STATES, seen.map(&:last)
    assert_equal [ "both" ], seen.map(&:first).uniq, "converted records must not be excluded either"
    assert_equal %w[approved unapproved], records.map { |record| record["id"] }
  end
end
