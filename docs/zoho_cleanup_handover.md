# Zoho Accounts cleanup — handover

Written 10 Sep 2026 at the end of a remote Claude Code session, for whoever picks
this up locally. It is deliberately standalone: it assumes no memory of the
session that produced it.

Audit report (full worklist, all six action categories):
<https://claude.ai/code/artifact/231e35b8-8d50-4fba-9b9d-9ec6819d14ab>

---

## 1. Why work locally

Two things were blocked in the remote container and are not blocked locally.

**The test suite has never run.** The container had Ruby 3.3.6 against the
Gemfile's pinned 3.4.4, no bundle installed and no Postgres, so Rails could not
boot. `bin/rails test`, `bin/rubocop` and `bin/brakeman` have never executed
against `lib/zoho/`. GitHub Actions has also never run on this fork — zero
workflows registered, zero runs — so CI will not cover it either. This is the
one open caveat on PR #1.

**The cleanup is ~450 records.** Every CRM write so far went through one MCP
tool call at a time. Locally, with OAuth credentials in the environment,
`Zoho::Client` can run the worklist in a loop with a dry-run pass first — which
is what it was built for.

### Getting started

```bash
git fetch origin claude/merge-lead-zoho-utility-0d99cb
git checkout claude/merge-lead-zoho-utility-0d99cb
bin/setup                 # bundle + db:prepare
bin/rails test test/lib/zoho/   # 38 tests, should pass
bin/rubocop -f github -a
bin/brakeman --no-pager
```

Zoho credentials (self-client OAuth, Zoho API console):

| Variable | Notes |
| --- | --- |
| `ZOHO_CLIENT_ID` | required |
| `ZOHO_CLIENT_SECRET` | required |
| `ZOHO_REFRESH_TOKEN` | required |
| `ZOHO_ACCOUNTS_DOMAIN` | defaults to `https://accounts.zoho.eu` |
| `ZOHO_API_DOMAIN` | defaults to `https://www.zohoapis.eu` |

The org (id `20097707983`) is on the **EU** datacenter, so the defaults are
correct. Confirm before pointing at anything.

---

## 2. What is already in the repo

| File | Role |
| --- | --- |
| `lib/zoho/client.rb` | Zoho v8 REST client, stdlib only. Has `query` (COQL), `search_all_records`, CRUD. |
| `lib/zoho/company_name.rb` | Name normalisation; separates companies, vessels and filler. |
| `lib/zoho/account_resolver.rb` | Five-outcome account matching. Only `matched` acts unattended. |
| `lib/zoho/lead_to_contact.rb` | Lead→contact merge rules. Pure, no I/O. |
| `lib/zoho/lead_to_contact/runner.rb` | Gathers leads, resolves records, applies. |
| `lib/tasks/zoho.rake` | `zoho:merge_lead` entry point. |
| `docs/zoho_lead_merge.md` | Usage and merge/matching rules. |

There is **no bulk-cleanup script yet.** Writing one is the natural first local
task — `Zoho::Client` already has everything it needs.

### Two Accounts fields were added in Zoho

- **`Aliases`** (multi-line text) — alternative spellings, one per line.
  `AccountResolver` matches against it, so a spelling recorded once resolves
  automatically thereafter. Populate this on every merge keeper.
- **`Vessel`** (lookup → Vessels) — for a vessel-owning entity that legitimately
  needs its own account, pointing at the Vessels registry instead of duplicating it.

---

## 3. What has already been changed in the CRM

**A backup was downloaded by Sascha before any of this.** Four merge clusters are
complete. Every losing record was verified clear of attachments before deletion.

| Cluster | Keeper | Action taken | Deleted |
| --- | --- | --- | --- |
| Team Italia | `696428000005509149` Team Italia Marine | Aliases set. No repoints needed (keeper already held all 6 contacts). | `696428000005509132` |
| MP Tech Solutions | `696428000007912016` | Kept the record holding the 1 contact. Names were byte-identical, so no alias needed. | `696428000000495928` |
| Current Corp | `696428000006718014` Current Corp | 1 contact repointed (`696428000000497655` Greg Menzies). Aliases set. | `696428000000495197`, `696428000000495196` |
| SeaKeepers | `696428000004456050` | 1 contact repointed (`696428000006851101`). **Renamed** `seakeepers.org` → `The International SeaKeepers Society`. Aliases set. | `696428000006851082`, `696428000006848028` |

Verified after the fact: Current Corp holds 2 contacts, SeaKeepers 3, Team Italia
6, MP Tech 1. Net: **1,853 → 1,847 accounts.**

Deleted records sit in the Zoho recycle bin for ~60 days.

---

## 4. The keeper rule — this corrects the audit report

The published report names a keeper per cluster chosen on *name quality*. That
was wrong and the report has not been regenerated. **Use the rule below, not the
report's keeper column.**

> Keep the record that already holds the most dependencies, then rename it to the
> preferred name.

Renaming is one write. Repointing is one write per dependency, each a chance to
orphan something. The clearest case: the report proposed `Alewijnse`
(`696428000006845048`) as keeper, but that record holds **zero** contacts while
`Alewijnse Marine Systems` (`696428000000466704`) holds **ten**. Keeping the
former would have meant 11 needless repoints.

---

## 5. Remaining phase 1 — four clusters, dependency counts verified

Counts below were measured, not estimated. **Deals, Quotes, Sales Orders,
Invoices, Calls, Meetings and child-accounts are empty across all of these** —
the only live dependencies are contacts, one note and one task.

### Alewijnse — 4 records → 1

Sascha's decision: all Alewijnse combines into **one** business, Tijssen included.

| Record | Id | Contacts |
| --- | --- | --- |
| **KEEP** Alewijnse Marine Systems → rename to `Alewijnse` | `696428000000466704` | 10 |
| Alewijnse | `696428000006845048` | 0 |
| Tijssen Elektro \| Alewijnse company | `696428000006864020` | 0 |
| TIJSSEN ELEKTRO | `696428000005629261` | 1 (`696428000000497575` Eddy Huisman) |

Aliases to set: `Alewijnse Marine Systems`, `Tijssen Elektro`, `TIJSSEN ELEKTRO`,
`Tijssen Elektro | Alewijnse company`.

### Van Berge Henegouwen — 4 records → 1 (worst cluster in the module)

| Record | Id | Contacts |
| --- | --- | --- |
| **KEEP** VBH - van Berge Henegouwen → rename to `Van Berge Henegouwen` | `696428000005631372` | 11 |
| VBH | `696428000005631355` | 5 + **1 note** |
| Van Berge Henegouwen (VBH) | `696428000006850004` | 2 |
| Van Berge Henegouwen | `696428000007597013` | 1 |

Contacts to repoint (8): `696428000006719010`, `696428000006719011`,
`696428000006719012`, `696428000006853106`, `696428000008706007`,
`696428000001095011`, `696428000005631268`, `696428000007597015`.

Note to move: `696428000008716001` "Role inbox (account-level)" — see §7 for why
this needs recreating rather than updating.

Aliases to set: `VBH`, `VBH - van Berge Henegouwen`, `Van Berge Henegouwen (VBH)`.

### Eekels — 4 records → 1

| Record | Id | Contacts |
| --- | --- | --- |
| **KEEP** Eekels → rename to `Eekels Technology B.V.` | `696428000000495273` | 3 |
| Eekels Technology B.V. | `696428000006845045` | 1 (`696428000005629897`) |
| Eekels Marpower eXperience | `696428000000495274` | 0 + **1 task** |
| eekels Technology | `696428000000495275` | 0 |

Task to repoint: `696428000001547129` "Follow up after Sea View Email" — its
`What_Id` points at `696428000000495274`.

"Marpower eXperience" is an event, not an entity. Aliases: `Eekels`,
`eekels Technology`, `Eekels Marpower eXperience`.

### Delius Klasing — 4 records → 1

| Record | Id | Contacts |
| --- | --- | --- |
| **KEEP** Delius Klasing → rename to `Delius Klasing Verlag GmbH` | `696428000006698008` | 4 |
| Delius Klasing Verlag GmbH / BOOTE EXCLUSIV | `696428000006847006` | 1 (`696428000006847022`) |
| BCN Group / Delius Klasing | `696428000006718002` | 1 (`696428000006718064`) |
| Media - Boote Exclusive | `696428000000495369` | 2 (`696428000005051001`, `696428000005051165`) |

Aliases: `Delius Klasing`, `BOOTE EXCLUSIV`, `Boote Exclusive`, `BCN Group`.

### Order of operations per cluster

1. Re-read the cluster from Zoho. **Do not trust the ids above blind** — verify
   before writing, in case the module moved on.
2. Check each losing record for attachments
   (`GET Accounts/{id}/Attachments`) — this cannot be done in COQL.
3. Repoint contacts: `PUT Contacts/{id}` with `Account_Name: {id: keeper}`.
4. Repoint activities: `PUT Tasks/{id}` with `What_Id: {id: keeper}`.
5. Recreate notes on the keeper, then delete the originals (§7).
6. Rename the keeper and set its `Aliases`.
7. Delete the losing records — **last**, only once 2–6 are confirmed.

---

## 6. Remaining phases — approximate scale

From the audit report. These are bulk field updates, not merges, and are where a
script pays off most.

| Phase | Records | Work |
| --- | --- | --- |
| Merge, remaining clusters | ~90 | 43 straight two-record pairs plus the rest. Zoho's native merge (Setup → Data Administration → Deduplication) repoints related records automatically and is safer than repoint-then-delete for these. |
| Parent/child groups | ~50 | Set `Parent_Account`; set `Account_Site` + billing address on children. Nothing is deleted. Feadship, MB92, Döhle, ELCOME, Furuno + 17 two-site pairs. |
| Vessels → Vessels module | ~140 | Merge the ~14 double-listed hulls first, then migrate. Link via the new `Vessel` field where an account is genuinely warranted. |
| Taxonomy prefix → field | ~110 | Strip `Association - `, `Events - ` etc. from names; move the classification into `Account_Type` / `Industry`. |
| People → Contacts | ~30 | Recreate as Contacts under their real employer. **Do not sweep up** Philippe Briand, Terence Disdale, Olesinski, Gregory C. Marshall, Koelln-Jacoby, Winch Design — those are studios named after founders. |
| Junk | ~22 | Check for attached records, then delete or rename. |

---

## 7. API limitations found the hard way

**Notes cannot be repointed.** `Parent_Id` is not updatable. To move a note,
read it, create a copy on the keeper, delete the original. Zoho's native merge
does this for you — a reason to prefer the UI for clusters carrying notes.

**Attachments are not queryable in COQL.** Only
`GET Accounts/{id}/Attachments`, one record at a time. Always check before
deleting.

**COQL has no working aggregate.** `select count(id) ... group by X` is rejected
with "select column should be given in group by clause" whichever way it is
written. Count by fetching rows and counting client-side.

**COQL needs explicit nesting past two conditions.** A flat
`a or b or c` is a syntax error. Use `((a or b) or c)`.
`AccountResolver#or_clause` already does this.

**The search endpoint hides records by two separate defaults** — `converted`
defaults to false and `approval_state` defaults to approved. A web-form lead
awaiting approval is invisible to an ordinary search, and that is routinely the
*richest* record for a person. `Client#search_all_records` sweeps both axes.
This cost real time to discover; do not remove it.

**`getRecord` returns empty for a converted lead.** Fetch converted leads
through search with `converted: "both"` instead.

---

## 8. Open decisions — need Sascha, not a script

- **SCC** — is `SCC Technologies Corporation` (`696428000007698003`) a distinct
  entity from `SCC Wireless` (`696428000007733001` / `696428000007698002`), or the
  same firm renamed?
- **Wärtsilä** — `SAM Electronics` and `FUNA` are acquired brands. Parent/child
  is probably more accurate than merge.
- **Probably NOT duplicates** — look before acting: `BURGESS` /
  `Burgess Marine` (brokerage vs an unrelated shipyard), `Atlantis Electronic
  Services` / `Atlantis Management`, `LINC` / `Linc Security Systems`, `IDEA` /
  `IDEA DATA Solutions`, `Titan Marine Engineering` / `Titan Marine Networks`,
  `Smart Advisers` / `Smart Technology Advisers`.
- **`De Vogt Naval Architects`** (`696428000007876090`) is almost certainly
  **De Voogt** misspelled — Feadship's naval architecture arm. Worth correcting
  while re-parenting the Feadship group.
- **House spelling** — 30+ accounts use `Super Yacht` / `Superyacht` /
  `SuperYacht` interchangeably. Not duplicates, but it defeats name search.
- **Duplicate contact spotted in passing** — `Gill Rodrigues` appears twice on
  The International SeaKeepers Society: `696428000004510361` and
  `696428000006851101`. Outside this audit's scope; the Contacts module has not
  been audited at all.

---

## 9. Also outstanding

**The `autoMergeLeadIntoContact` Deluge function.** This org runs a workflow rule
"Auto-merge Lead into existing Contact" that fires on lead approval and
**deletes the lead**. During this session it deleted lead
`696428000009126001` (Antonio Moledo Correa, Website Contact Form) moments after
approval. Its data survived only because it had been merged onto the contact
minutes earlier. Anything that function fails to carry across is unrecoverable —
there is no record left to re-run against. Read it and decide whether it or
`Zoho::LeadToContact` should own the job; they currently overlap.

**PR #1** — <https://github.com/RPV-SK/maybeFinance/pull/1> — open as a draft,
mergeable, 4 commits. Needs the test/lint/security run described in §1 before it
should merge. No CI will do this for you.

---

## 10. Verification queries

```sql
-- account count (expect 1847 after phase-1 work so far)
select id from Accounts where id is not null limit 200 offset 1800

-- a cluster's current state
select id, Account_Name, Aliases, Parent_Account from Accounts
where ((Account_Name like '%Eekels%' or Account_Name like '%Berge%')
    or (Account_Name like '%Alewijnse%' or Account_Name like '%Tijssen%')) limit 30

-- contacts hanging off a set of accounts (counts come from row count)
select id, Full_Name, Account_Name from Contacts
where Account_Name in ('<id>','<id>') limit 200

-- dependencies that are NOT contacts
select id, Parent_Id, Note_Title from Notes where Parent_Id in ('<id>') limit 200
select id, Subject, What_Id from Tasks where What_Id in ('<id>') limit 200
select id, Account_Name, Parent_Account from Accounts where Parent_Account in ('<id>') limit 200
```
