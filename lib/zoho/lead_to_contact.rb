module Zoho
  # Folds a Zoho CRM lead's data onto an existing contact.
  #
  # Zoho's own lead conversion only populates a *new* contact, and it silently
  # drops anything it cannot map — most notably the lead's free-text `Company`,
  # which has nowhere to go unless an Account already exists. That is exactly how
  # a converted contact ends up with no company on it. This class makes the whole
  # mapping explicit: every lead field is either copied, deliberately skipped, or
  # reported as a warning, and nothing is lost quietly.
  #
  # Planning is pure — it does no network I/O — so the merge rules can be tested
  # directly. `Runner` (see lib/zoho/lead_to_contact/runner.rb) does the talking.
  #
  #   plan = Zoho::LeadToContact.new(lead: lead, contact: contact).plan
  #   plan.changes  # => { "Phone" => "+34 ...", "Description" => "..." }
  #
  class LeadToContact
    # Lead field => contact field. Anything not listed here is handled below or
    # intentionally left behind.
    FIELD_MAP = {
      "Salutation" => "Salutation",
      "First_Name" => "First_Name",
      "Last_Name" => "Last_Name",
      "Email" => "Email",
      "Secondary_Email" => "Secondary_Email",
      "Phone" => "Phone",
      "Mobile" => "Mobile",
      "Fax" => "Fax",
      "Designation" => "Title",
      "Website" => "Company_URL",
      "Skype_ID" => "Skype_ID",
      "Twitter" => "Twitter",
      "Street" => "Mailing_Street",
      "City" => "Mailing_City",
      "State" => "Mailing_State",
      "Zip_Code" => "Mailing_Zip",
      "Country" => "Mailing_Country",
      "Lead_Source" => "Lead_Source",
      "Email_Opt_Out" => "Email_Opt_Out",
      "How_did_you_hear_about_us" => "How_did_you_hear_about_us",
      "Segment_Value_Proposition" => "Segment_Value_Proposition",
      "GA_Client_ID" => "GA_Client_ID",
      "Visitor_UID" => "Visitor_UID",
      "Visitor_Score" => "Visitor_Score",
      "First_Visited_URL" => "First_Visited_URL",
      "First_Visited_Time" => "First_Visited_Time",
      "Last_Visited_Time" => "Last_Visited_Time",
      "Days_Visited" => "Days_Visited",
      "Number_Of_Chats" => "Number_Of_Chats",
      "Average_Time_Spent_Minutes" => "Average_Time_Spent_Minutes",
      "Referrer" => "Referrer"
    }.freeze

    # Firmographics describe the company, not the person — they belong on the
    # Account, so we surface them instead of dropping them on the contact.
    ACCOUNT_FIELDS = %w[Company Industry No_of_Employees Annual_Revenue].freeze

    # Meaningful only while the record is a lead.
    LEAD_ONLY_FIELDS = %w[Rating Lead_Status Lead_Conversion_Time Converted_Contact Converted_Account Converted_Deal].freeze

    # Appended rather than replaced: a contact's description is usually hand-written.
    APPENDED_FIELDS = %w[Description].freeze

    Plan = Struct.new(:changes, :skipped, :warnings, keyword_init: true) do
      def empty?
        changes.empty?
      end

      def to_s
        lines = []
        lines << (changes.any? ? "Changes:" : "Changes: (none — contact already has everything the lead holds)")
        changes.each { |field, value| lines << "  #{field} = #{value.inspect}" }

        if skipped.any?
          lines << "Skipped (contact value kept):"
          skipped.each { |field, reason| lines << "  #{field}: #{reason}" }
        end

        if warnings.any?
          lines << "Warnings:"
          warnings.each { |warning| lines << "  #{warning}" }
        end

        lines.join("\n")
      end
    end

    # strategy:
    #   :fill_blanks (default) — only write contact fields that are currently empty
    #   :prefer_lead           — lead values win, but a blank lead field never
    #                            erases a populated contact field
    def initialize(lead:, contact:, strategy: :fill_blanks, account_id: nil, now: Time.current)
      raise ArgumentError, "unknown strategy #{strategy.inspect}" unless %i[fill_blanks prefer_lead].include?(strategy)

      @lead = lead.to_h
      @contact = contact.to_h
      @strategy = strategy
      @account_id = account_id
      @now = now
    end

    def plan
      changes = {}
      skipped = {}
      warnings = []

      FIELD_MAP.each do |lead_field, contact_field|
        lead_value = normalize(lead[lead_field])
        next if lead_value.nil? # a blank lead field is not data — never let it erase the contact

        contact_value = normalize(contact[contact_field])

        if contact_value.nil?
          changes[contact_field] = lead_value
        elsif contact_value == lead_value
          next
        elsif strategy == :prefer_lead
          changes[contact_field] = lead_value
          warnings << "#{contact_field}: overwrote #{contact_value.inspect} with lead value #{lead_value.inspect}"
        else
          skipped[contact_field] = "contact has #{contact_value.inspect}, lead has #{lead_value.inspect}"
        end
      end

      merged_description = merge_description
      changes["Description"] = merged_description if merged_description

      apply_account(changes, warnings)
      warn_about_account_fields(warnings)

      Plan.new(changes: changes, skipped: skipped, warnings: warnings)
    end

    private
      attr_reader :lead, :contact, :strategy, :account_id, :now

      # The company gap this utility exists to close: a lead's `Company` is free
      # text, a contact's company is an Account lookup. Without an account id
      # there is nowhere to put it, so say so loudly rather than losing it.
      def apply_account(changes, warnings)
        company = normalize(lead["Company"])
        existing_account = contact["Account_Name"]

        if account_id.present?
          if existing_account.present? && existing_account["id"] != account_id
            warnings << "Account_Name: contact is already linked to #{existing_account["name"].inspect} (#{existing_account["id"]}); not relinking"
            return
          end

          changes["Account_Name"] = { "id" => account_id } if existing_account.blank?
        elsif company.present? && existing_account.blank?
          warnings << "Lead company #{company.inspect} has no Account to link to — resolve or create the Account and re-run with account_id:"
        end
      end

      def warn_about_account_fields(warnings)
        carried = (ACCOUNT_FIELDS - [ "Company" ]).select { |field| normalize(lead[field]).present? }
        return if carried.empty?

        warnings << "Not copied to the contact (these belong on the Account): #{carried.join(", ")}"
      end

      # Append the lead's description under a provenance stamp so the merge is
      # auditable later and a second run does not duplicate it.
      def merge_description
        stamp = "[Lead merge #{now.strftime("%d %b %Y")}] Merged from lead #{lead["id"]}."
        stamp_key = "Merged from lead #{lead["id"]}."

        current = normalize(contact["Description"])
        lead_description = normalize(lead["Description"])

        return nil if current.to_s.include?(stamp_key)

        body = [ stamp ]
        body << lead_description if lead_description.present? && !current.to_s.include?(lead_description)

        [ current, body.join(" ") ].compact.join("\n\n")
      end

      def normalize(value)
        case value
        when String then value.strip.presence
        when nil then nil
        else value
        end
      end
  end
end
