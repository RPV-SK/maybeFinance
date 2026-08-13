namespace :zoho do
  desc "Merge a Zoho CRM lead's data into its contact. Usage: rake 'zoho:merge_lead[LEAD_ID_OR_EMAIL]' [CONTACT=id] [STRATEGY=fill_blanks|prefer_lead] [CREATE_ACCOUNT=true] [DRY_RUN=true]"
  task :merge_lead, [ :lead ] => :environment do |_task, args|
    lead = args[:lead].presence || ENV["LEAD"].presence
    abort "Pass a lead id or email: rake 'zoho:merge_lead[696428000009119001]'" if lead.blank?

    Zoho::LeadToContact::Runner.new.call(
      lead: lead,
      contact: ENV["CONTACT"].presence,
      strategy: (ENV["STRATEGY"].presence || "fill_blanks").to_sym,
      create_account: ENV["CREATE_ACCOUNT"] == "true",
      dry_run: ENV["DRY_RUN"] == "true"
    )
  end
end
