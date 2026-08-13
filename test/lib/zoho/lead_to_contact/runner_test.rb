require "test_helper"

class Zoho::LeadToContact::RunnerTest < ActiveSupport::TestCase
  # Collects log lines so assertions can read what the run reported.
  class TestLogger
    attr_reader :lines

    def initialize
      @lines = []
    end

    def info(message)
      @lines << message.to_s
    end

    def to_s
      lines.join("\n")
    end
  end

  class FakeClient
    attr_reader :updates, :created

    def initialize(leads: [], contacts: [], accounts: [])
      @leads = leads
      @contacts = contacts
      @accounts = accounts
      @updates = []
      @created = []
    end

    def find_record(module_name, id, fields: nil)
      collection_for(module_name).find { |record| record["id"] == id }
    end

    def search_all_records(module_name, criteria:, fields: nil, approval_states: nil)
      collection_for(module_name)
    end

    def create_record(module_name, attributes)
      @created << [ module_name, attributes ]
      { "id" => "acc-new" }
    end

    def update_record(module_name, id, attributes)
      @updates << [ module_name, id, attributes ]
      { "id" => id }
    end

    private
      def collection_for(module_name)
        case module_name
        when "Leads" then @leads
        when "Contacts" then @contacts
        when "Accounts" then @accounts
        end
      end
  end

  setup do
    # Mirrors the real pair: a sparse PDF-download lead that was converted, plus a
    # richer contact-form lead created 17 minutes later that Zoho's default search
    # hides because it is still awaiting approval.
    @sparse_lead = {
      "id" => "lead-1",
      "Created_Time" => "2026-08-13T11:48:28+01:00",
      "First_Name" => "Antonio",
      "Last_Name" => "Moledo Correa",
      "Email" => "amc@example.com",
      "Description" => "Detection Range",
      "Lead_Source" => "PDF Download",
      "Converted__s" => true,
      "Converted_Contact" => { "id" => "contact-1" }
    }

    @rich_lead = {
      "id" => "lead-2",
      "Created_Time" => "2026-08-13T12:05:42+01:00",
      "First_Name" => "Antonio",
      "Last_Name" => "Moledo Correa",
      "Email" => "amc@example.com",
      "Company" => "INTERNATIONAL MARINE SYSTEM SARL",
      "Designation" => "CTO & Co-founder",
      "Phone" => "+212 662423914",
      "Description" => "We are looking for electro-optical and thermal imaging solutions.",
      "Lead_Source" => "Website Contact Form",
      "Converted__s" => false,
      "$approval_state" => "webform_unapproved"
    }

    @contact = { "id" => "contact-1", "Full_Name" => "Antonio Moledo Correa", "Email" => "amc@example.com" }
    @logger = TestLogger.new
  end

  test "folds every lead for the email into the contact, including unapproved ones" do
    changes = merge

    assert_equal "CTO & Co-founder", changes["Title"]
    assert_equal "+212 662423914", changes["Phone"]
    assert_match "electro-optical", changes["Description"]
    assert_match "Detection Range", changes["Description"]
  end

  test "earlier leads win under fill_blanks, so first-touch attribution survives" do
    assert_equal "PDF Download", merge["Lead_Source"]
  end

  test "writes once, with the accumulated changes" do
    client = build_client
    Zoho::LeadToContact::Runner.new(client: client, logger: @logger).call(lead: "amc@example.com")

    assert_equal 1, client.updates.size
    module_name, id, _attributes = client.updates.first
    assert_equal [ "Contacts", "contact-1" ], [ module_name, id ]
  end

  test "dry run writes nothing" do
    client = build_client
    Zoho::LeadToContact::Runner.new(client: client, logger: @logger).call(lead: "amc@example.com", dry_run: true)

    assert_empty client.updates
  end

  test "reports leads left unconverted so they do not rot in the module" do
    merge

    assert_match "lead-2", @logger.to_s
    assert_match "still unconverted", @logger.to_s
  end

  test "creates the account named by a lead company when asked" do
    client = build_client
    Zoho::LeadToContact::Runner.new(client: client, logger: @logger).call(lead: "amc@example.com", create_account: true)

    assert_equal [ [ "Accounts", { "Account_Name" => "INTERNATIONAL MARINE SYSTEM SARL" } ] ], client.created
  end

  private
    def build_client
      FakeClient.new(leads: [ @rich_lead, @sparse_lead ], contacts: [ @contact ])
    end

    def merge(**options)
      Zoho::LeadToContact::Runner.new(client: build_client, logger: @logger).call(lead: "amc@example.com", **options)
    end
end
