# Power Pages credential discovery — add-on modules

CLM ships two **optional add-on solutions** specifically for Power Pages credentials. They install on top of the core CLM solutions and use the same `clm_credential` / `clm_renewalevent` storage. Customers without Power Pages skip these entirely.

## What gets covered

| Cert type | Where it lives | Add-on that covers it | SP perms required |
|---|---|---|---|
| **IdP signing certs** (SAML, OpenID Connect, WS-Federation) | Dataverse table `adx_setting` or `mspp_sitesetting`, rows where name ends in `/Certificate` | **CLMDiscoveryFlow_PowerPages** (automated) | App User in Power Pages env with read on Power Pages tables |
| **Custom domain SSL/TLS certs** (BYO uploaded via Power Platform admin center, like `pp-contoso.example.com` in the example) | Power Platform service backend (NOT in Dataverse) | **`Seed-CLMPortalCerts.ps1`** (manual CSV) — see Add-on 2 below for why API-based discovery was parked | Caller has Create/Update on `clm_credential` |
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

Seed-CLMPortalCerts.ps1 + portal_certs.csv                  ← manual entry for
                                                              BYO custom domain SSL
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

## Add-on 2: CSV-driven manual entry — `Seed-CLMPortalCerts.ps1` (BYO SSL certs)

### Why manual instead of API discovery

The original design was an automated discovery flow against `api.bap.microsoft.com` / `api.powerplatform.com`. After significant investigation we parked it because:

- Microsoft retired the `api.bap.microsoft.com/.../powerpages/sites` endpoint (404 across all supported api-versions).
- The replacement endpoint at `api.powerplatform.com/powerpages/environments/{envId}/websites` requires the SP to hold an RBAC role assigned via the new Power Platform Authorization API.
- Even after granting the SP `Power Platform Administrator` Entra role AND `Power Platform Reader` RBAC role, the Power Pages sub-route specifically still returned authorization denied in our tenant.
- The API surface is in active migration; Microsoft hasn't published a stable supported pattern for SP access to Power Pages cert metadata yet.

So instead: **ops maintains a CSV** with one row per BYO SSL cert. The script upserts CLM credential rows from the CSV. Re-run on cert renewal (just update the ExpiryDate column).

### CSV format

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
