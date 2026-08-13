module Zoho
  class LeadToContact
    # Wires LeadToContact up to the CRM: finds the records, resolves the Account
    # the lead's company points at, then applies (or just prints) the plan.
    #
    # One person often has *several* leads — a PDF download and a contact-form
    # enquiry an hour apart, say — and the richest one is frequently the one
    # still awaiting approval, which Zoho's search hides by default. So this
    # gathers every lead for the email and folds them in oldest-first, rather
    # than merging whichever single record happened to surface.
    class Runner
      class NotFound < StandardError; end

      def initialize(client: Zoho::Client.new, logger: nil)
        @client = client
        @logger = logger
      end

      # lead:        lead id, or an email address to gather every lead for
      # contact:     contact id — defaults to a lead's converted contact, then
      #              to a contact with the same email
      # strategy:    :fill_blanks (default) or :prefer_lead
      # create_account: create the Account named by a lead's Company if missing
      # dry_run:     build and return the plan without writing anything
      def call(lead:, contact: nil, strategy: :fill_blanks, create_account: false, dry_run: false)
        leads = find_leads(lead)
        contact_record = find_contact(contact, leads)

        log "Contact #{contact_record["id"]} (#{contact_record["Full_Name"]}) <- #{leads.size} lead#{"s" unless leads.one?}"

        # Each lead plans against the contact as the previous leads have left it,
        # so later leads fill only what is still blank and descriptions stack in
        # chronological order.
        contact_state = contact_record.dup
        changes = {}

        leads.each do |lead_record|
          account_id = resolve_account_id(lead_record, contact_state, create_account: create_account, dry_run: dry_run)

          plan = LeadToContact.new(
            lead: lead_record,
            contact: contact_state,
            strategy: strategy,
            account_id: account_id
          ).plan

          log "\nLead #{lead_record["id"]} (#{lead_record["Lead_Source"]}, created #{lead_record["Created_Time"]})#{" [#{lead_record["$approval_state"]}]" if unapproved?(lead_record)}"
          log plan.to_s

          contact_state.merge!(plan.changes)
          changes.merge!(plan.changes)
        end

        warn_about_leftovers(leads)

        if dry_run
          log "\nDry run — nothing written."
        elsif changes.empty?
          log "\nNothing to write."
        else
          client.update_record("Contacts", contact_record["id"], changes)
          log "\nContact #{contact_record["id"]} updated (#{changes.keys.size} fields)."
        end

        changes
      end

      private
        attr_reader :client, :logger

        def find_leads(lead)
          leads =
            if lead.to_s.include?("@")
              client.search_all_records("Leads", criteria: "(Email:equals:#{lead})")
            else
              Array(client.find_record("Leads", lead))
            end

          raise NotFound, "No lead found for #{lead.inspect}" if leads.empty?

          leads.sort_by { |record| record["Created_Time"].to_s }
        end

        def find_contact(contact, leads)
          if contact.present?
            record = client.find_record("Contacts", contact)
            return record if record
            raise NotFound, "No contact found for #{contact.inspect}"
          end

          converted = leads.filter_map { |lead| lead.dig("Converted_Contact", "id") }.uniq
          if converted.many?
            raise NotFound, "Leads point at more than one contact (#{converted.join(", ")}) — pass contact: to choose"
          end

          if converted.any? && (record = client.find_record("Contacts", converted.first))
            return record
          end

          email = leads.filter_map { |lead| lead["Email"] }.first
          raise NotFound, "No converted contact and no email to match on" if email.blank?

          record = client.search_all_records("Contacts", criteria: "(Email:equals:#{email})").first
          record or raise NotFound, "No contact matches #{email} — convert a lead first, or pass contact:"
        end

        def resolve_account_id(lead_record, contact_state, create_account:, dry_run:)
          return contact_state.dig("Account_Name", "id") if contact_state["Account_Name"].present?

          company = lead_record["Company"].to_s.strip
          return nil if company.blank?

          result = account_resolver.resolve(company)
          log result.to_s

          return result.account_id if result.matched?

          # Ambiguous and placeholder both refuse to create. Guessing wrong here
          # is expensive: a duplicate Account splits a customer's history in two.
          return nil unless result.creatable?

          unless create_account
            log "Re-run with create_account: true to create it."
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

        def account_resolver
          @account_resolver ||= Zoho::AccountResolver.new(client: client)
        end

        # Merging copies the data across but leaves the lead itself alone. Say so,
        # so an unapproved or unconverted lead is not left to rot in the module.
        def warn_about_leftovers(leads)
          leftovers = leads.reject { |lead| lead["Converted__s"] || lead.dig("$converted_detail", "contact").present? }
          return if leftovers.empty?

          leftovers.each do |lead|
            state = unapproved?(lead) ? " (#{lead["$approval_state"]})" : ""
            log "Note: lead #{lead["id"]}#{state} is still unconverted — its data is now on the contact, but the lead record remains."
          end
        end

        def unapproved?(lead)
          lead["$approval_state"].present? && lead["$approval_state"] != "approved"
        end

        def log(message)
          return if message.nil?

          logger ? logger.info(message) : puts(message)
        end
    end
  end
end
