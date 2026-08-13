require "test_helper"

class Zoho::LeadToContactTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 8, 13, 12, 0, 0)
    @lead = {
      "id" => "111",
      "First_Name" => "Antonio",
      "Last_Name" => "Moledo Correa",
      "Email" => "amc@internationalmarinesystem.com",
      "Company" => "INTERNATIONAL MARINE SYSTEM SARL",
      "Designation" => "Technical Director",
      "Phone" => nil,
      "Description" => "Detection Range",
      "Lead_Source" => "PDF Download"
    }
  end

  test "copies lead fields onto a blank contact" do
    plan = build_plan(contact: { "id" => "222" })

    assert_equal "Antonio", plan.changes["First_Name"]
    assert_equal "Technical Director", plan.changes["Title"]
    assert_equal "PDF Download", plan.changes["Lead_Source"]
  end

  test "fill_blanks keeps the contact's value and reports the conflict" do
    plan = build_plan(contact: { "id" => "222", "Title" => "Managing Director" })

    assert_nil plan.changes["Title"]
    assert_match "Managing Director", plan.skipped["Title"]
  end

  test "prefer_lead overwrites and warns" do
    plan = build_plan(contact: { "id" => "222", "Title" => "Managing Director" }, strategy: :prefer_lead)

    assert_equal "Technical Director", plan.changes["Title"]
    assert plan.warnings.any? { |warning| warning.include?("Title") }
  end

  test "a blank lead field never erases a populated contact field" do
    plan = build_plan(contact: { "id" => "222", "Phone" => "+34 600 000 000" }, strategy: :prefer_lead)

    assert_not plan.changes.key?("Phone")
  end

  test "appends the lead description under a provenance stamp" do
    plan = build_plan(contact: { "id" => "222", "Description" => "Met at METS." })

    assert_match "Met at METS.", plan.changes["Description"]
    assert_match "Merged from lead 111.", plan.changes["Description"]
    assert_match "Detection Range", plan.changes["Description"]
  end

  test "re-running does not stamp the description twice" do
    already_merged = "Detection Range\n\n[Lead merge 13 Aug 2026] Merged from lead 111."
    plan = build_plan(contact: { "id" => "222", "Description" => already_merged })

    assert_not plan.changes.key?("Description")
  end

  test "warns when the lead's company has no account to land on" do
    plan = build_plan(contact: { "id" => "222" })

    assert_not plan.changes.key?("Account_Name")
    assert plan.warnings.any? { |warning| warning.include?("INTERNATIONAL MARINE SYSTEM SARL") }
  end

  test "links the account when one is supplied" do
    plan = build_plan(contact: { "id" => "222" }, account_id: "333")

    assert_equal({ "id" => "333" }, plan.changes["Account_Name"])
  end

  test "does not relink a contact that already belongs to another account" do
    contact = { "id" => "222", "Account_Name" => { "id" => "999", "name" => "Other Co" } }
    plan = build_plan(contact: contact, account_id: "333")

    assert_not plan.changes.key?("Account_Name")
    assert plan.warnings.any? { |warning| warning.include?("Other Co") }
  end

  private
    def build_plan(contact:, strategy: :fill_blanks, account_id: nil)
      Zoho::LeadToContact.new(
        lead: @lead,
        contact: contact,
        strategy: strategy,
        account_id: account_id,
        now: @now
      ).plan
    end
end
