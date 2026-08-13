require "test_helper"

# The cases here are real values taken from the CRM, not invented ones.
class Zoho::CompanyNameTest < ActiveSupport::TestCase
  test "normalize strips legal form, punctuation and case" do
    assert_equal "royal van lent shipyard feadship",
      Zoho::CompanyName.normalize("Royal van Lent Shipyard B.V. (Feadship)")
    assert_equal "tui cruises", Zoho::CompanyName.normalize("TUI Cruises GmbH")
  end

  test "same? ignores legal form and case but not extra words" do
    assert Zoho::CompanyName.same?("Sunreef Yachts B.V.", "Sunreef Yachts")
    assert Zoho::CompanyName.same?("turquoise yachts", "Turquoise Yachts")
    assert_not Zoho::CompanyName.same?("MB92 Barcelona", "MB92")
  end

  test "related? spots the same company under a longer or shorter name" do
    assert Zoho::CompanyName.related?("MB92 Barcelona", "MB92")
    assert Zoho::CompanyName.related?("MB92 Group", "MB92")
    assert Zoho::CompanyName.related?("Monaco Marine", "Monaco Marine La Ciotat")
    assert Zoho::CompanyName.related?("Alewijnse Marine Systems", "Alewijnse")
    assert Zoho::CompanyName.related?("Royal Van Lent Shipyard", "Royal van Lent Shipyard B.V. (Feadship)")
  end

  test "related? is not fooled by shared generic words" do
    assert_not Zoho::CompanyName.related?("Prime Marine", "Euro Marine Group")
    assert_not Zoho::CompanyName.related?("Super Yachts", "Turquoise Yachts")
    assert_not Zoho::CompanyName.related?("Monaco Marine", "Prime Marine")
  end

  test "placeholder? rejects vessels and filler" do
    [
      "Private Yacht", "Motoryacht", "Super Yachts", "M/Y Amadeus",
      "87m Feadship", "96m Feadship", "M/Y Feadship 75m+",
      "Sunseeker predator 82 feet", "N/A", "Unknown", "freelance"
    ].each do |value|
      assert Zoho::CompanyName.placeholder?(value), "#{value.inspect} should be rejected"
    end
  end

  test "placeholder? accepts real companies" do
    [
      "Alewijnse Marine Systems", "FEADSHIP", "MB92 Barcelona",
      "INTERNATIONAL MARINE SYSTEM SARL", "TUI Cruises GmbH", "Carnival Corporation"
    ].each do |value|
      assert_not Zoho::CompanyName.placeholder?(value), "#{value.inspect} should be accepted"
    end
  end

  test "search_tokens drops generic and short words" do
    assert_equal [ "feadship" ], Zoho::CompanyName.search_tokens("87m Feadship")
    assert_equal [ "alewijnse" ], Zoho::CompanyName.search_tokens("Alewijnse Marine Systems")
  end
end
