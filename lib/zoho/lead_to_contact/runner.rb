module Zoho
  class LeadToContact
    # Wires LeadToContact up to the CRM: finds the records, resolves the Account
    # the lead's company points at, then applies (or just prints) the plan.
    class Runner
      class NotFound < StandardError; end

      def initialize(client: Zoho::Client.new, logger: nil)
        @client = client
        @logger = logger
      end

      # lead:        lead id, or an email address to look one up by
      # contact:     contact id — defaults to the lead's converted contact, then
      #              to a contact with the same email
      # strategy:    :fill_blanks (default) or :prefer_lead
      # create_account: create the Account named by the lead's Company if missing
      # dry_run:     build and return the plan without writing anything
      def call(lead:, contact: nil, strategy: :fill_blanks, create_account: false, dry_run: false)
        lead_record = find_lead(lead)
        contact_record = find_contact(contact, lead_record)
        account_id = resolve_account_id(lead_record, contact_record, create_account: create_account, dry_run: dry_run)

        plan = LeadToContact.new(
          lead: lead_record,
          contact: contact_record,
          strategy: strategy,
          account_id: account_id
        ).plan

        log "Lead #{lead_record["id"]} (#{lead_record["Full_Name"]}) -> Contact #{contact_record["id"]} (#{contact_record["Full_Name"]})"
        log plan.to_s

        if dry_run
          log "Dry run — nothing written."
        elsif plan.empty?
          log "Nothing to write."
        else
          client.update_record("Contacts", contact_record["id"], plan.changes)
          log "Contact #{contact_record["id"]} updated."
        end

        plan
      end

      private
        attr_reader :client, :logger

        def find_lead(lead)
          record =
            if lead.to_s.include?("@")
              # Converted leads are excluded from search by default.
              client.search_records("Leads", criteria: "(Email:equals:#{lead})", converted: "both").first
            else
              client.find_record("Leads", lead)
            end

          record or raise NotFound, "No lead found for #{lead.inspect}"
        end

        def find_contact(contact, lead_record)
          if contact.present?
            record = client.find_record("Contacts", contact)
            return record if record
            raise NotFound, "No contact found for #{contact.inspect}"
          end

          if (converted = lead_record["Converted_Contact"]).present?
            record = client.find_record("Contacts", converted["id"])
            return record if record
          end

          email = lead_record["Email"]
          raise NotFound, "Lead #{lead_record["id"]} has no converted contact and no email to match on" if email.blank?

          record = client.search_records("Contacts", criteria: "(Email:equals:#{email})").first
          record or raise NotFound, "No contact matches lead #{lead_record["id"]} (#{email}) — convert the lead first, or pass contact:"
        end

        def resolve_account_id(lead_record, contact_record, create_account:, dry_run:)
          return contact_record.dig("Account_Name", "id") if contact_record["Account_Name"].present?

          company = lead_record["Company"].to_s.strip
          return nil if company.blank?

          existing = client.search_records("Accounts", criteria: "(Account_Name:equals:#{company})", fields: "id,Account_Name").first
          if existing
            log "Matched Account #{existing["id"]} for company #{company.inspect}."
            return existing["id"]
          end

          unless create_account
            log "No Account named #{company.inspect}. Re-run with create_account: true to create one."
            return nil
          end

          if dry_run
            log "Would create Account #{company.inspect}."
            return nil
          end

          created = client.create_record("Accounts", { "Account_Name" => company })
          log "Created Account #{created["id"]} for #{company.inspect}."
          created["id"]
        end

        def log(message)
          return if message.blank?

          logger ? logger.info(message) : puts(message)
        end
    end
  end
end
