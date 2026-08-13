# Zoho lead → contact merge

Folds a Zoho CRM lead's data onto an existing contact.

Zoho's built-in lead conversion only populates a *brand new* contact, and it drops
anything it cannot map — most visibly the lead's free-text `Company`, which has
nowhere to land unless a matching Account already exists. That is how a converted
contact ends up with no company on it. This utility makes the mapping explicit:
every lead field is copied, deliberately skipped, or reported as a warning.

It also gathers **every** lead for the person, not just the one that happens to
surface. Two of Zoho's search defaults hide records:

- `converted` defaults to `false`, so already-converted leads disappear
- `approval_state` defaults to approved, so a web-form lead sitting in
  `webform_unapproved` disappears too

Those two together are how the richest lead for a person — the contact-form
enquiry with the company, title, phone and the whole qualification story — can be
invisible while a sparse PDF-download lead is the only one you can see.
`Zoho::Client#search_all_records` sweeps across both axes and de-duplicates.

## Setup

Credentials come from the environment (self-client OAuth in the Zoho API console):

| Variable | Notes |
| --- | --- |
| `ZOHO_CLIENT_ID` | required |
| `ZOHO_CLIENT_SECRET` | required |
| `ZOHO_REFRESH_TOKEN` | required |
| `ZOHO_ACCOUNTS_DOMAIN` | defaults to `https://accounts.zoho.eu` |
| `ZOHO_API_DOMAIN` | defaults to `https://www.zohoapis.eu` |

The defaults target the EU datacenter. Set both domains if the org lives elsewhere
(`.com`, `.in`, `.com.au`, …).

## Usage

```bash
# See what would change — writes nothing
DRY_RUN=true bin/rails 'zoho:merge_lead[696428000009119001]'

# Apply it
bin/rails 'zoho:merge_lead[696428000009119001]'

# Look the lead up by email, and create the Account named by its Company
CREATE_ACCOUNT=true bin/rails 'zoho:merge_lead[amc@internationalmarinesystem.com]'

# Target a specific contact and let lead values win over contact values
CONTACT=696428000009128001 STRATEGY=prefer_lead bin/rails 'zoho:merge_lead[696428000009119001]'
```

Passing an **email** gathers every lead for that address; passing a **lead id**
merges just that one. The contact is resolved in this order: the `CONTACT` you
pass, then a lead's converted contact, then a contact with the same email.

## Merge rules

- Multiple leads are folded in **oldest first**, each planning against the contact
  as the previous leads left it. So first-touch values (`Lead_Source`) survive,
  later leads fill only what is still blank, and descriptions stack in
  chronological order.
- **`fill_blanks` (default)** — only writes contact fields that are currently
  empty. Conflicts are listed under "Skipped" rather than applied.
- **`prefer_lead`** — lead values win, and each overwrite is printed as a warning.
- A blank lead field never erases a populated contact field, under either strategy.
- `Description` is **appended**, not replaced, under a `[Lead merge <date>] Merged
  from lead <id>.` stamp. Re-running is a no-op rather than a duplicate.
- `Company` needs an Account lookup — see **Account matching** below. A contact
  already linked to a *different* Account is never relinked.
- Firmographics (`Industry`, `No_of_Employees`, `Annual_Revenue`) are reported,
  not copied — they describe the company, so they belong on the Account.
- Merging copies data across but leaves the lead records alone. Any lead left
  unconverted is called out at the end of the run, so it is not forgotten.

## Account matching

Matching lead `Company` against `Account_Name` **exactly** finds a match about one
time in eight in this database, so an exact-match-then-create rule does not fill a
gap — it manufactures duplicates. Measured here: Feadship is spelled twelve ways
across its leads (`Royal Van Lent Shipyard`, `Feadship Royal Van Lent`,
`87m Feadship`, `Feadship Amsterdam`) while two Feadship Accounts already exist;
`MB92 Barcelona` and `MB92 Group` sit against an account called plain `MB92`.

So `Zoho::AccountResolver` normalises both sides — case, accents, punctuation and
legal form (`B.V.`, `GmbH`, `SARL`) — searches Accounts on the identifying tokens
rather than the whole string, and returns one of four outcomes:

| Outcome | Meaning | Action |
| --- | --- | --- |
| `matched` | normalised names identical | links the Account |
| `ambiguous` | related Accounts exist | lists them, links and creates **nothing** |
| `placeholder` | names a vessel or is filler | never creates an Account |
| `absent` | nothing resembling it exists | creates one, given `CREATE_ACCOUNT=true` |

Only `matched` is acted on unattended. A wrong guess is expensive — a duplicate
Account splits a customer's history in two — so ambiguity is handed back to a
human along with the candidate list.

The `placeholder` guard matters because lead `Company` frequently holds something
that is not a company at all: `Private Yacht`, `Motoryacht`, `M/Y Amadeus`,
`87m Feadship`, `Sunseeker predator 82 feet`. `Private Yacht` is already an
Account in this org, so this has happened before.

Token overlap is only ever a *suggestion*: `MB92 Barcelona` will not silently
attach itself to `MB92`, because they may genuinely be different yards.

## Note on the existing automation

This org already has a workflow rule, "Auto-merge Lead into existing Contact",
backed by a Deluge function `autoMergeLeadIntoContact`. It fires on approval and
**deletes** the lead. Anything that function fails to carry across is gone with
it, with no record left to re-run against — so prefer running this utility (or at
minimum `DRY_RUN=true`) *before* approving a web-form lead.

## Layout

| File | Role |
| --- | --- |
| `lib/zoho/lead_to_contact.rb` | The merge rules. Pure — no network I/O, so it is directly testable. |
| `lib/zoho/lead_to_contact/runner.rb` | Finds the records, resolves the Account, applies the plan. |
| `lib/zoho/client.rb` | Minimal Zoho v8 REST client (stdlib only). |
| `lib/tasks/zoho.rake` | The `zoho:merge_lead` entry point. |
| `test/lib/zoho/lead_to_contact_test.rb` | Covers the merge rules. |
