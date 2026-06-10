# Credential Lifecycle Manager (CLM)

A Power Platform solution that **automatically discovers, owns, and reminds on expiring secrets/certs** across Azure and Entra ID, without spreadsheets or tribal knowledge.

## What it does

- **Discovers** credentials daily from Microsoft Graph (AAD app registration passwords/keys) and Azure Resource Manager (Key Vault secrets) via two custom connectors backed by an AAD service principal
- **Resolves owners** in priority order: Azure resource `tag.Owner` → AAD app first owner → regex/substring rules → manual. Tag changes propagate automatically (tag is source of truth)
- **Sends reminders** to owners via Microsoft Teams DM and email on a 90/60/30/14/7/1/D0/Overdue cadence
- **Records coverage gaps** — every subscription / vault the discovery SP can't read shows up as a triagable row with HTTP status + remediation hint
- **Surfaces everything** in a model-driven app with curated views (Expiring 30d, Orphans, Open Gaps, My Credentials, Renewal Events timeline)

## Architecture

```
┌──────────────────────┐     ┌──────────────────────┐
│ AAD App Registration │     │ Azure Subscriptions  │
│ (Graph permissions)  │     │ + Key Vaults         │
└──────────┬───────────┘     └──────────┬───────────┘
           │ daily 02:00                │ daily 02:00
           ▼                            ▼
┌─────────────────────────────────────────────────┐
│  Discovery flow (CLMDiscoveryFlow)              │
│  • Graph leg: applications + owners             │
│  • ARM leg:   subscriptions → vaults → secrets  │
│  • Tag capture (clm_ownertag)                   │
│  • Coverage gap upsert on 4xx/5xx               │
└────────────────────┬────────────────────────────┘
                     ▼
         ┌───────────────────────┐
         │ clm_credential (DV)   │   ← daily 03:00
         │ clm_renewalevent (DV) │     Owner Resolver
         │ clm_coveragegap (DV)  │     (tag SoT + rules)
         │ clm_ownerrule (DV)    │
         │ clm_sourceenvironment │   ← daily 07:00
         └─────────┬─────────────┘     Reminder Engine
                   ▼                   (Teams + email)
       ┌────────────────────────┐
       │ Model-driven app:      │
       │ Credential Lifecycle   │
       └────────────────────────┘
```

## Components in this repo

| Path | What it is | Latest version |
|---|---|---|
| `schema_csv/` | Human-readable column reference for all 5 tables + option sets | n/a |
| `solution_manifest.json` | Declarative spec consumed by `Deploy-CLMSchema.ps1` | n/a |
| `clmPlatformOps_1_0_0_1.zip` | Publisher solution (`clm` prefix) | 1.0.0.1 |
| `CredentialLifecycleManager_1_0_0_3.zip` | Schema solution (tables, columns, choices, security roles) | 1.0.0.3 |
| `CLMDiscoveryFlow_1_0_0_23.zip` | Discovery flow + 2 custom connectors (AppReg + Enterprise App + KV) | 1.0.0.23 |
| `CLMOwnerResolver_1_0_0_5.zip` | Owner Resolver flow | 1.0.0.5 |
| `CLMReminderEngine_1_0_0_7.zip` | Reminder Engine flow (Approvals + email) | 1.0.0.7 |
| `CLMApp_1_0_0_1.zip` | Model-driven app + 10 views + 4 charts + CLM Operations dashboard | 1.0.0.1 |
| `CLMDiscoveryFlow_PowerPages_1_0_0_4.zip` | **Optional add-on**: Power Pages IdP signing certs (Dataverse-based, schema-probing) | 1.0.0.4 |
| `Get-CLMPortalCertsViaAdminApi.ps1` | **Automated** Power Pages BYO custom-domain SSL discovery. Enumerates all portals in the tenant, filters to those with `CustomHostNames`, fetches every uploaded SSL cert, dedupes per thumbprint, and upserts into `clm_credential` (`clm_externalid = pp:custom:<portalId>:<thumbprint>`). Supports `-Interactive` (MSAL sign-in via `Az.Accounts`, no DevTools needed) or `-AdminCenterToken` (paste a captured JWT). ⚠️ **Uses undocumented admin-center endpoints** (`portalsitewide-{region}.portal-infra.dynamics.com`) — not covered by Microsoft SLA, no SP/app-only auth. See [`docs/POWER_PAGES_DISCOVERY.md`](docs/POWER_PAGES_DISCOVERY.md). | n/a |
| `Seed-CLMPortalCerts.ps1` | **CSV-driven fallback** for Power Pages BYO custom-domain SSL certs. Use when the admin-API path isn't viable (regional cluster differs, token capture not available, fully air-gapped workflow). | n/a |
| `portal_certs.sample.csv` | Sample CSV for `Seed-CLMPortalCerts.ps1` | n/a |
| `CLMApp_Sitemap.xml` | Paste-in sitemap for the model-driven app | n/a |
| `connector/`, `docs/` | Source connector swagger + design docs | n/a |
| `Deploy-CLMSchema.ps1` | Idempotent schema deployment via Dataverse Web API | n/a |
| `Add-CLMOwnerColumns.ps1` | Adds `clm_ownertag` + `clm_ownersource` columns | n/a |
| `Add-CLMAppViews.ps1` | Creates 10 curated public views for the model-driven app | n/a |
| `Add-CLMAppCharts.ps1` | Creates 4 charts (Status pie, Source column, Type doughnut, Events bar) | n/a |
| `Add-CLMAppDashboard.ps1` | Creates the CLM Operations system dashboard | n/a |
| `Seed-CLMOwnerRules.ps1` | Idempotent owner-rule seeder (edit `$Rules` at top) | n/a |
| `Register-CLMDiscoveryApp.ps1` | Creates the AAD app registration + cert for the SP | n/a |
| `Add-DelegatedPermissions.ps1` | Grants admin consent for Graph permissions | n/a |

> **Placeholders:** scripts and zips have been scrubbed of tenant-identifying values. You'll see `<TENANT_ID>`, `<CLIENT_ID>`, `<DATAVERSE_HOST>`, `<OPS_EMAIL>` — replace with your values (or pass via parameters) before running.

## Prerequisites

- A Power Platform **Premium** environment (custom connectors + premium flows)
- An AAD account with **System Customizer** (or System Admin) in that Dataverse env
- An AAD account that can create **app registrations** in your tenant
- An Azure subscription where the discovery SP will be granted RBAC (Key Vault Reader at minimum)
- PowerShell 7+ on the deploying machine (`Az.Accounts` module — auto-installed)

## Deployment order (one-time)

> Replace `https://<DATAVERSE_HOST>` with your env URL throughout.

### 1. Deploy schema (5 tables + option sets + alt keys)

```powershell
pwsh ./Deploy-CLMSchema.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>
```

Then in the maker portal:
- Open the **clm_credential** table → **+ New column** → Name `clm_daysuntilexpiry`, Type **Formula**, formula: `DateDiff(Now(), 'Expiry Date', TimeUnit.Days)`. (Calculated/Formula columns can't be created cleanly via Web API.)

### 2. Add the tag / ownersource columns

```powershell
pwsh ./Add-CLMOwnerColumns.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>
```

### 3. Register the Discovery AAD app + grant permissions

```powershell
pwsh ./Register-CLMDiscoveryApp.ps1 -DataverseEnvironmentUrl https://<DATAVERSE_HOST>
pwsh ./Add-DelegatedPermissions.ps1
```

#### Microsoft Graph permissions (Application)
| Permission | Why |
|---|---|
| `Application.Read.All` | List AAD app registrations and read their `passwordCredentials` / `keyCredentials` |
| `Organization.Read.All` | Read tenant id + primary verified domain (used to populate `clm_tenantid` and `clm_environment`) |

Both require **admin consent** (granted via the Add-DelegatedPermissions script or manually in the Entra portal).

#### Azure RBAC (per subscription you want scanned)
| Role | Scope | Why |
|---|---|---|
| `Reader` | Subscription | Lists Key Vaults (`Microsoft.KeyVault/vaults/read`). Without this, the ARM leg records a coverage gap for the whole subscription. |
| `Key Vault Reader` | Subscription or each vault | Reads vault metadata including secret list and expiry attributes (`Microsoft.KeyVault/vaults/secrets/read`). Note: this is the **management plane** role; the discovery flow does **not** read secret *values*, only metadata, so no data-plane access policy / RBAC is needed. |

Grant via Az CLI or the Azure portal:

```bash
SP_OBJECT_ID="<service-principal-object-id-from-script-output>"
SUB_ID="<subscription-id>"

az role assignment create --assignee-object-id $SP_OBJECT_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Reader" --scope "/subscriptions/$SUB_ID"

az role assignment create --assignee-object-id $SP_OBJECT_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Reader" --scope "/subscriptions/$SUB_ID"
```

Repeat per subscription. Coverage gaps are auto-recorded with HTTP status + remediation hint for any subscription/vault the SP can't read, so missing RBAC shows up in the **Open Gaps** view in the model-driven app.

#### Why not Managed Identity?
Power Platform **custom connectors do not support Azure Managed Identity as an authentication scheme** — only OAuth2, API key, and Basic. The AAD App Registration with a client secret (or cert) is the required pattern when discovery runs from a Power Automate flow. To use a Managed Identity instead, you'd have to re-host the discovery work as an Azure Function / Logic App and call it from a thin HTTP custom connector — significantly larger redesign for a marginal security improvement (the SP credentials live in Power Platform, not in code, and are auto-rotated by Microsoft for the connector's OAuth secret).

#### Add as Dataverse Application User
Add the resulting client ID as a **Dataverse Application User** with role `CLM Platform Ops` (see prompt printed by `Register-CLMDiscoveryApp.ps1`). This lets the SP write `clm_credential` / `clm_renewalevent` / `clm_coveragegap` rows.

### 4. Import the publisher and schema solutions

In https://make.powerapps.com → target env → Solutions → Import:
- `clmPlatformOps_1_0_0_1.zip`
- `CredentialLifecycleManager_1_0_0_3.zip`

### 5. Custom connectors

When you import `CLMDiscoveryFlow_1_0_0_23.zip` in step 7, the two custom connectors land automatically. **Before** importing the flow, however:

1. Open each new custom connector → **Security** tab → paste the Discovery app's **Client Secret** (or upload the cert if using cert auth) → **Update connector**
2. Add the connector's **Redirect URL** to the AAD app's **Authentication** blade (typically `https://global.consent.azure-apim.net/redirect`)
3. **Connections** (left rail) → **+ New connection** → create one connection per custom connector + one each for **Microsoft Dataverse**, **Office 365 Outlook**, and **Approvals**

### 6. Pre-create connection references

Solutions → CLMDiscoveryFlow (or any solution) → **+ New** → **More** → **Connection reference**:
- `clm_dataverse` → Dataverse connection
- `clm_clmazurediscovery` → clmarmdiscovery connection
- `clm_clmgraphdiscovery` → clmgraphdiscovery connection
- `clm_office365` → Office 365 Outlook connection (for reminder emails)
- `clm_approvals` → Approvals connection (for owner action cards in Teams/Outlook)

### 7. Import the three flow solutions

Solutions → Import (in order):
1. `CLMDiscoveryFlow_1_0_0_23.zip` — bind the 3 connection refs when prompted
2. `CLMOwnerResolver_1_0_0_5.zip` — binds `clm_dataverse`
3. `CLMReminderEngine_1_0_0_7.zip` — binds `clm_dataverse` + `clm_office365` + `clm_approvals`

After each import, open the flow and **Turn on**.

### 8. (Optional) Create env variables

Solutions → CLMReminderEngine → **+ New** → **More** → **Environment variable**:

| Schema name | Type | Default value | Purpose |
|---|---|---|---|
| `clm_platformopsemail` | Text | your ops alias | Fallback recipient when an owner can't be resolved |
| `clm_credentialformurl_template` | Text | `https://<DATAVERSE_HOST>/main.aspx?appid=<APPID>&pagetype=entityrecord&etn=clm_credential&id=` | Used in Approval card's "open in CLM" link (admins). Trailing `id=` is intentional — flow appends credentialId. |

If you skip these, the flow falls back to the hard-coded `<OPS_EMAIL>` literal and a `#?id=` no-op link.

### 9. Seed the SYSTEM credential and starter rules

In Power Apps → Tables → Credential → **+ New row**: `clm_name = "SYSTEM"` (used by flows for leg-level failure events).

```powershell
# Edit $Rules at the top of this script first
pwsh ./Seed-CLMOwnerRules.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>
```

### 10. Create the model-driven app

```powershell
pwsh ./Add-CLMAppViews.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>
```

Then in the maker portal:
1. **+ New → App → Model-driven app** → name `Credential Lifecycle`
2. **+ Add page → Dataverse table** → add (with Show in navigation):
   - `clm_credential` (set as **Home**)
   - `clm_renewalevent`, `clm_ownerrule`, `clm_sourceenvironment`, `clm_coveragegap`
3. **Save → Publish**
4. (Optional) Sitemap customisation. The modern app designer **does not expose XML mode**, so use one of:
   - Edit groups/areas via the **Navigation** pane in the modern designer (drag/drop)
   - OR use the **classic solution explorer**: Solutions → your solution → **Site Map** component → Edit → Show XML → paste contents of `CLMApp_Sitemap.xml`

### 11. First run

- **Discovery-CLMCredentials** → Run on demand. Credential rows appear; `clm_ownertag` populated from Azure tags / AAD owners; gaps recorded for any unreadable scopes
- **OwnerResolver-CLMCredentials** → Run. Tag-driven owners assigned, then rule fallback fires
- **Reminder-CLMCredentials** → Run. Owners with credentials expiring in ≤ 90 days get a Teams DM + email

### 12. (Optional) Charts + dashboard

```powershell
pwsh ./Add-CLMAppCharts.ps1    -EnvironmentUrl https://<DATAVERSE_HOST>
pwsh ./Add-CLMAppDashboard.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>
```

Then in the maker portal:
1. Open the **Credential Lifecycle** app in Edit
2. Sitemap → **+ Add page** → **Dashboard** → pick **CLM Operations** → Add
3. Save → Publish

You now see the dashboard in the app's left nav. It has:
- Credentials by Status (pie)
- Credentials by Source System (column)
- Open Coverage Gaps (live list)
- Recent Renewal Events (last 7 days, live list)

### 13. (Optional) Customize the credential main form

The default auto-generated form works, but a curated form makes triage much faster. Recommended structure:

| Section | Columns to include |
|---|---|
| **Header (always visible)** | Name, Status, Days Until Expiry, Owner (User) |
| **Identity** tab | External Id, Source System, Credential Type, Object Id, Key Id, Display Name |
| **Expiry** tab | Expiry Date, Days Until Expiry, Not Before, Last Discovered On, Reminders Sent, Last Reminder On, Suppressed Until |
| **Ownership** tab | Owner (User), Owner (Team), Owner Tag, Owner Source, Owner Locked, Manager (User) |
| **Source** tab | Source Display Name, Environment / Subscription, Tenant Id, Source Environment (lookup), Source Portal URL, Risk Score |
| **Audit** tab | Renewal Events related grid (subgrid → Renewal Events → Credential lookup) |

**To build it (10 min in UI):**
1. Power Apps → Tables → Credential → **Forms** → click **Information** (default main form) → **Edit form**
2. **+ Add tab** for each tab above
3. **+ Add field** to drop columns into sections
4. **+ Component → Subgrid** on the Audit tab → Table: Renewal Events → Default view: Recent Events (7 days)
5. Save → Publish

For a Status colour badge, add the **Status** field to the header and set its display to **Read-only** then use form formatting (modern designer → Properties → Formatting → Colour by value).

## How owner resolution works

Every credential gets an owner via this priority chain (run daily by the OwnerResolver flow):

1. **Locked** (`clm_ownerlocked = true`) → skip — manual edits win
2. **Tag-driven** — if `clm_ownertag` is an email that resolves to a Dataverse user, that user becomes the owner. Tag values come from Azure resource `tags.Owner` and AAD application owners.
3. **Stale-tag cleanup** — if the previous owner came from a tag that's no longer valid, clear it so Phase 4 can re-assign
4. **Rule fallback** — `clm_ownerrule` rows are evaluated in priority order (ascending). First match wins. Rules match on credential display name, environment, or vault name using case-insensitive substring patterns.

The credential's `clm_ownersource` field shows which phase set the current owner: `Tag`, `AADOwner`, `Rule`, or `Manual`.

**For deep guidance** — rule writing patterns, troubleshooting, validation views, and tuning checklist — see [`docs/OWNER_RESOLUTION.md`](docs/OWNER_RESOLUTION.md).

## Cross-environment deployment

To deploy CLM into a new environment (test / customer prod / staging), import these solution zips in order. Each can be redownloaded from this repo's root.

| # | Solution zip | What it contains | Connection refs to bind |
|---|---|---|---|
| 1 | `clmPlatformOps_1_0_0_1.zip` | Publisher (`clm` prefix) | none |
| 2 | `CredentialLifecycleManager_1_0_0_3.zip` | 5 tables, 8 option sets, alt keys, **security roles** | none |
| 3 | `CLMDiscoveryFlow_1_0_0_23.zip` | Discovery flow + 2 custom connectors | `clm_dataverse`, `clm_clmgraphdiscovery`, `clm_clmazurediscovery` |
| 4 | `CLMOwnerResolver_1_0_0_5.zip` | Owner Resolver flow | `clm_dataverse` |
| 5 | `CLMReminderEngine_1_0_0_7.zip` | Reminder Engine (Approvals + email) | `clm_dataverse`, `clm_office365`, `clm_approvals` |
| 6 | `CLMApp_1_0_0_1.zip` | Model-driven app, 10 views, 4 charts, dashboard | none |

### Pre-import prep
- Schema columns added by `Add-CLMOwnerColumns.ps1` and the formula column `clm_daysuntilexpiry` must exist before importing the flows (they reference these fields). Schema solution v3 covers `clm_ownertag` and `clm_ownersource`; the formula column still needs the maker-portal step in section 1.
- Custom connector OAuth client secrets get **wiped** on connector import — re-paste them in the connector's Security tab after the Discovery import.
- Create connections (Dataverse, custom connectors, Office 365, Approvals) **before** binding connection references during flow import.

### Post-import steps
1. Add the SP as a **Dataverse Application User** with the **CLM Platform Ops** security role (now shipped in schema v3)
2. Grant Azure RBAC to the SP per subscription (Reader + Key Vault Reader — see Step 3 in the deployment runbook)
3. Seed `clm_ownerrule` rows for the target tenant's naming conventions (edit `Seed-CLMOwnerRules.ps1`)
4. Create env variables for the target env: `clm_platformopsemail`, `clm_credentialformurl_template` (URLs differ per env — get the app ID from the new env)
5. Turn on all three flows + run once on demand

### Differences between unmanaged and managed solutions
All the zips in this repo are **unmanaged** — fine for in-tenant deployment, but for handing off to customers you may want managed. To produce managed versions:
- Open the source solution in the maker portal
- Export → choose **Managed** for the package type
- Customers can then import as managed (locks down customization, easier to support, harder to debug)

## Daily schedule (AUS Eastern)

| Time | Flow | Purpose |
|---|---|---|
| 02:00 | Discovery | Pulls AAD + ARM credentials, populates tags, records gaps |
| 03:00 | Owner Resolver | Assigns owners from tag → rule, writes audit events |
| 07:00 | Reminder Engine | Emails owner + posts Approvals card (Teams/Outlook) with I'll renew / Snooze 7 days / Reassign to me options. Owner action is processed without requiring a Power Apps license. |

## How to extend

### Add a new discovery source
1. Add the connector definition + operation to `connector/`
2. Update Discovery flow with a new Leg scope using the same upsert pattern: `Lookup by clm_externalid → If exists Update else Create`
3. Wrap in `Try_*` / `Catch_*` for coverage-gap recording (see ARM_Leg as template)

### Add a new reminder bucket
Edit the bucket priority list in the Reminder Engine flow's `Compose_TargetBucket` action. Bucket priority is descending (Overdue > D0 > … > D90).

### Add a custom owner-resolution scope
Add an entry to `clm_matchscope` option set + update Owner Resolver's `Filter_Matching_Rules` `where` expression to evaluate the new scope.

### Lock an owner against auto-reassignment
Set `clm_ownerlocked = true` on the credential row. Both Owner Resolver and Reminder Engine respect this.

## Schema reference

| Table | Purpose | Key columns |
|---|---|---|
| `clm_credential` | One row per discovered secret / cert / key | `clm_externalid` (alt key), `clm_status`, `clm_expirydate`, `clm_daysuntilexpiry`, `clm_owneruser`, `clm_ownertag`, `clm_ownersource`, `clm_ownerlocked`, `clm_remindersent` |
| `clm_sourceenvironment` | Scopes that discovery scans (PP envs, subs, tenants, KVs) | `clm_externalid` (alt key), `clm_scopetype`, `clm_isenabled` |
| `clm_coveragegap` | Every scope discovery couldn't enumerate, with HTTP detail | `clm_externalid` (alt key), `clm_gaptype`, `clm_status`, `clm_lasthttpstatus`, `clm_resolutionhint` |
| `clm_renewalevent` | Append-only history (Discovered, ReminderSent, Reassigned, MarkedOrphaned, …) | `clm_action`, `clm_credentialid`, `clm_occurredon` |
| `clm_ownerrule` | Regex/substring-based fallback ownership rules | `clm_priority`, `clm_matchscope`, `clm_matchpattern`, `clm_isactive`, `clm_matchcount` |

See `schema_csv/` for full column lists, [`docs/RBAC_AND_COVERAGE.md`](docs/RBAC_AND_COVERAGE.md) for the SP RBAC matrix, [`docs/OWNER_RESOLUTION.md`](docs/OWNER_RESOLUTION.md) for the owner-rule engine deep dive, and [`docs/POWER_PAGES_DISCOVERY.md`](docs/POWER_PAGES_DISCOVERY.md) for the two Power Pages add-ons (IdP + BYO SSL).

## License

Internal MS use — adapt freely. Customer deliverables may require separate licensing review.
