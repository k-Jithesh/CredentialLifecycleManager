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
| `CredentialLifecycleManager_1_0_0_2.zip` | Schema solution (tables, columns, choices) | 1.0.0.2 |
| `CLMDiscoveryFlow_1_0_0_22.zip` | Discovery flow + 2 custom connectors (AppReg + Enterprise App + KV) | 1.0.0.22 |
| `CLMOwnerResolver_1_0_0_5.zip` | Owner Resolver flow | 1.0.0.5 |
| `CLMReminderEngine_1_0_0_7.zip` | Reminder Engine flow (Approvals + email) | 1.0.0.7 |
| `CLMApp_Sitemap.xml` | Paste-in sitemap for the model-driven app | n/a |
| `connector/`, `docs/` | Source connector swagger + design docs | n/a |
| `Deploy-CLMSchema.ps1` | Idempotent schema deployment via Dataverse Web API | n/a |
| `Add-CLMOwnerColumns.ps1` | Adds `clm_ownertag` + `clm_ownersource` columns | n/a |
| `Add-CLMAppViews.ps1` | Creates 10 curated public views for the model-driven app | n/a |
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
- `CredentialLifecycleManager_1_0_0_2.zip`

### 5. Custom connectors

When you import `CLMDiscoveryFlow_1_0_0_22.zip` in step 7, the two custom connectors land automatically. **Before** importing the flow, however:

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
1. `CLMDiscoveryFlow_1_0_0_22.zip` — bind the 3 connection refs when prompted
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

See `schema_csv/` for full column lists, and `docs/RBAC_AND_COVERAGE.md` for the SP RBAC matrix.

## License

Internal MS use — adapt freely. Customer deliverables may require separate licensing review.
