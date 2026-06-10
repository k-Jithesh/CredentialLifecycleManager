# Power Pages credential discovery — add-on modules

CLM ships two **optional add-on solutions** specifically for Power Pages credentials. They install on top of the core CLM solutions and use the same `clm_credential` / `clm_renewalevent` storage. Customers without Power Pages skip these entirely.

## What gets covered

| Cert type | Where it lives | Add-on that covers it | SP perms required |
|---|---|---|---|
| **IdP signing certs** (SAML, OpenID Connect, WS-Federation) | Dataverse table `adx_setting` or `mspp_sitesetting`, rows where name ends in `/Certificate` | **CLMDiscoveryFlow_PowerPages** (automated) | App User in Power Pages env with read on Power Pages tables |
| **Custom domain SSL/TLS certs** (BYO uploaded via Power Platform admin center, like `pp-contoso.example.com` in the example) | Power Platform service backend (NOT in Dataverse) | **`Get-CLMPortalCertsViaAdminApi.ps1`** (automated, undocumented admin-center API) or **`Seed-CLMPortalCerts.ps1`** (CSV fallback) — see Add-on 2 below | Caller has Power Platform Administrator role + Create/Update on `clm_credential` |
| **Microsoft-managed SSL certs** (default Power Pages cert for `*.microsoftcrmportals.com`) | Microsoft manages renewal automatically | Not tracked (nothing to do) | n/a |

## Solution layout

```
CredentialLifecycleManager (schema, security roles)         ← required
   │
   ├── CLMDiscoveryFlow (core: Graph + ARM legs)            ← required
   ├── CLMOwnerResolver                                     ← required
   ├── CLMReminderEngine                                    ← required
   ├── CLMApp (views, charts, dashboard)                    ← required
   │
   └── CLMDiscoveryFlow_PowerPages                          ← optional add-on
         covers IdP signing certs (Dataverse-side)

Seed-CLMPortalCerts.ps1 + portal_certs.csv                  ← CSV fallback for
Get-CLMPortalCertsViaAdminApi.ps1                             BYO custom domain SSL
                                                              (preferred: admin-API)
```

Each add-on is independent. Install only what's needed.

## Add-on 1: CLMDiscoveryFlow_PowerPages (IdP signing certs)

### What it does
1. Daily 02:30 AUS Eastern run
2. **Probes** the Power Pages env for `mspp_websites` (modern Power Pages schema). If unavailable, falls back to `adx_websites` (legacy portal schema)
3. For each site, queries `*_sitesetting` rows where `name endswith '/Certificate'` (this is the convention for IdP signing certs)
4. For each cert setting, upserts a `clm_credential` row with:
   - `clm_externalid = pp:<siteId>:<settingId>`
   - `clm_sourcesystem = 100000004` (Power Pages Site)
   - `clm_credentialtype = 200000001` (Certificate)
   - `clm_expirydate = null` ⚠️ — see note
   - `clm_sourceportalurl` = deep-link to the setting row in the Power Pages env
5. If neither schema readable, writes a `PowerPagesSchemaUnknown` orphan event so it's visible in **Failures** view

### Expiry parsing limitation ⚠️
Power Automate can't parse X.509 DER from base64 directly. For v1, **the expiry field is left blank** — owners or ops need to set it manually after the credential row appears. We can decode the cert via an Azure Function call in a future version (~3 hr build).

Workaround until then:
- The credential row still gets discovered + tracked + assigned an owner via rules/tag
- The Reminder Engine simply skips rows with null expiry (they don't trigger reminders)
- Open the credential form, paste the expiry date from a manual OpenSSL inspection of the cert

### Required setup

| Step | What | Where |
|---|---|---|
| 1 | Discovery SP must be a **Dataverse Application User** in the Power Pages env | Power Pages env → Settings → Users + permissions → Application users → + New app user |
| 2 | Assign the **Power Pages Service** security role (or a custom role with read on `adx_website`/`adx_setting` or `mspp_website`/`mspp_sitesetting`) | Same place |
| 3 | Create a **second Dataverse connection** in the CLM env, signed in as the SP, targeting the Power Pages env | Connections → + New connection → Dataverse → "Connect with service principal" → enter Client ID, Secret, Tenant ID, env URL of the **Power Pages env** |
| 4 | Create connection reference `clm_dataversepowerpages` | Solutions → CLMDiscoveryFlowPowerPages → + New → More → Connection reference → bind to the connection from step 3 |
| 5 | Set env variable `clm_powerpagesenvurl` | Solutions → CLMDiscoveryFlowPowerPages → + New → More → Environment variable → schema name `clm_powerpagesenvurl`, value = Power Pages env URL like `https://contoso.crm.dynamics.com/` (trailing slash) |
| 6 | Import `CLMDiscoveryFlow_PowerPages_1_0_0_4.zip` as **Update** | Solutions → Import |
| 7 | Bind both connection refs (`clm_dataverse` to CLM env, `clm_dataversepowerpages` to Power Pages env) | When prompted during import |
| 8 | Turn on the flow → Run on demand | Open flow → Turn on → Run |

### Schema probe behavior
Modern Power Pages schema (`mspp_*`) takes priority. Three outcomes:

| Probe result | What happens |
|---|---|
| `mspp_websites` reads OK | `PortalSchema` set to `modern`, flow uses `mspp_*` tables for the rest of the run |
| `mspp_websites` fails AND `adx_websites` reads OK | `PortalSchema` set to `legacy`, flow uses `adx_*` tables |
| Both fail | `PortalSchema` stays `unknown`, flow writes a `PowerPagesSchemaUnknown` event and terminates cleanly |

## Add-on 2: BYO custom-domain SSL certs (two options)

There are two ways to track BYO SSL certs in CLM. **Pick one per environment.**

### Option A (recommended): `Get-CLMPortalCertsViaAdminApi.ps1` — automated

Enumerates every portal in the tenant, filters to those with `CustomHostNames` set, fetches every uploaded SSL cert per portal (including certs that are uploaded but not yet bound), dedupes by thumbprint, and upserts into `clm_credential`.

```powershell
# Interactive sign-in (no DevTools step) - preferred
.\Get-CLMPortalCertsViaAdminApi.ps1 -Interactive `
    -DataverseHost '<DATAVERSE_HOST>'

# Dry-run to preview the upsert plan
.\Get-CLMPortalCertsViaAdminApi.ps1 -Interactive `
    -DataverseHost '<DATAVERSE_HOST>' -DryRun
```

**⚠️ Uses undocumented Microsoft internal endpoints.** Specifically:

| Endpoint | What it returns |
|---|---|
| `GET https://portalsitewide-{region}.portal-infra.dynamics.com/api/v1/powerPortal/ListPortals` | All Power Pages portals in the tenant (id, name, env, tenant, custom hostnames). Response is a JSON-string-wrapped JSON array (double-encoded). |
| `GET .../api/v1/admincenter/Certificate/GetCertificatesByPortal?tenantId=...&portalId=...&certType=SSL` | All SSL certs uploaded to that portal, one row per region the cert is replicated to. |

These are the same endpoints the Power Platform admin-center web UI calls. They are **not publicly documented**, **not covered by Microsoft SLA**, and may change or disappear without notice. The `HostRegion` (`oce`, `emea`, `amer`, `ind`, `jpn`, etc.) varies per tenant — check the host of the actual request in DevTools if you get 404.

**Auth: delegated user only.** Microsoft has not (as of writing) enabled service-principal / client-credentials auth on these endpoints. We tested this in detail:

- Granted SP the `Power Platform Administrator` Entra role: still 401/403
- Created RBAC role assignment via `api.powerplatform.com/authorization/roleAssignments` (`Power Platform Reader` at tenant scope): role assignment succeeded but the Power Pages sub-route still returned authorization denied

So the script uses **delegated user auth** via `Az.Accounts` (`-Interactive`) or a **captured JWT** (`-AdminCenterToken`) from the admin-center web UI. Caller must hold the **Power Platform Administrator** Entra role.

**If the admin-center API ever returns 401/403 or 404 across all `HostRegion` values, fall back to Option B.**

### Option B: `Seed-CLMPortalCerts.ps1` — CSV-driven fallback

For environments where the admin-API path is unusable (locked-down host, no DevTools access, Az.Accounts blocked, undocumented endpoints changed/disappeared), maintain a CSV with one row per BYO SSL cert. The script upserts CLM credential rows from the CSV. Re-run on cert renewal (just update the ExpiryDate column).

#### CSV format

```
SiteName,HostName,Thumbprint,ExpiryDate,OwnerEmail,Environment,Notes
Contact Portal,pp-contoso.example.com,71B279A778BC0FB04949966D06...,2026-11-29T23:59:59Z,jane.smith@org.com,prod,Customer portal
Permit Portal,pp-permit.example.com,82C390B889CD1FC15A5BAA77E17...,2027-03-15T23:59:59Z,it-platform@org.com,prod,
```

| Column | Required | Notes |
|---|---|---|
| SiteName | ✅ | Power Pages site display name |
| HostName | ✅ | Custom domain (also used in `clm_externalid`) |
| Thumbprint | ✅ | Cert thumbprint (used in `clm_externalid` for upsert key) |
| ExpiryDate | ✅ | ISO 8601 UTC, e.g. `2026-11-29T23:59:59Z` |
| OwnerEmail | optional | Resolves to systemuser; sets `clm_owneruser` + `clm_ownerlocked = true` so OwnerResolver doesn't auto-reassign |
| Environment | optional | Free text label (`prod`, `uat`, etc.) |
| Notes | optional | Appended to the auto-generated note |

Where to find these values in the portal: Power Platform admin center → your env → Sites → click the site → Manage custom domains → see the SSL/TLS certificates section (the screenshot above is exactly this).

### Run

```powershell
cd 'C:\path\to\repo'

# Preview - no changes
pwsh ./Seed-CLMPortalCerts.ps1 -EnvironmentUrl https://<DATAVERSE_HOST> -CsvPath ./portal_certs.csv -WhatIf

# Apply
pwsh ./Seed-CLMPortalCerts.ps1 -EnvironmentUrl https://<DATAVERSE_HOST> -CsvPath ./portal_certs.csv
```

### Idempotency
`clm_externalid` is computed as `pp:manual:<hostname>:<thumbprint>`. Re-runs UPDATE existing rows (same hostname + thumbprint) instead of duplicating. To rotate a cert:
1. Update the CSV with the new thumbprint + new expiry
2. Re-run the script
3. **Old row stays in CLM** with the old thumbprint — it'll get marked Expired when its expiry passes. Delete manually if you want to clean up.

### Required permissions
Caller of the script needs a Dataverse security role with **Create + Update on `clm_credential`** in the CLM env. The default **System Customizer** role works, or grant the **CLM Platform Ops** role from the schema solution.

### Future: revisit API-based discovery
When Microsoft publishes stable SP support for Power Pages cert reads (likely via the Authorization RBAC + Power Platform API path documented in [programmability-tutorial-rbac-role-assignment](https://learn.microsoft.com/en-us/power-platform/admin/programmability-tutorial-rbac-role-assignment)), we can replace this CSV approach with an automated flow leg. The schema (`clm_externalid = pp:custom:<envId>:<siteId>:<thumbprint>` vs `pp:manual:...`) leaves room for both to coexist.

## Multi-environment Power Pages (future v25)

Both add-ons currently target **one** Power Pages env per import. Customers with prod + UAT + dev portals should import the IdP add-on N times into the CLM env with different connection references (`clm_dataversepowerpages_prod`, `clm_dataversepowerpages_uat`, etc.) and run `Seed-CLMPortalCerts.ps1` once per env with the appropriate `-EnvironmentUrl`. A future Discovery flow could enumerate envs dynamically once Microsoft publishes stable SP-friendly Power Platform admin APIs.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| IdP add-on creates `PowerPagesSchemaUnknown` event every run | SP doesn't have read on either schema's website table | Check the Application User's security role in the Power Pages env |
| IdP add-on succeeds but no credentials appear | No `*_sitesetting` rows match `endswith name '/Certificate'`. Tenant may use custom auth providers with different naming. | Inspect site settings manually — adjust the `endswith()` filter if your naming differs |
| `Seed-CLMPortalCerts.ps1` rejects a row | Missing required column or invalid `ExpiryDate` format | CSV must have `SiteName,HostName,Thumbprint,ExpiryDate,OwnerEmail,Environment,Notes` with `ExpiryDate` as ISO-8601 (`2027-03-15T23:59:59Z`) |
| Seeded custom domain cert has wrong expiry | CSV value out of date vs the cert actually bound in the Power Platform admin center | Re-export from admin center, update CSV, re-run the seeder (it upserts on `clm_externalid`) |

---

Back to [README](../README.md).
