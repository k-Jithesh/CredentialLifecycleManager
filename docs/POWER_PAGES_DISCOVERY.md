# Power Pages credential discovery — add-on modules

CLM ships two **optional add-on solutions** specifically for Power Pages credentials. They install on top of the core CLM solutions and use the same `clm_credential` / `clm_renewalevent` storage. Customers without Power Pages skip these entirely.

## What gets covered

| Cert type | Where it lives | Add-on that covers it | SP perms required |
|---|---|---|---|
| **IdP signing certs** (SAML, OpenID Connect, WS-Federation) | Dataverse table `adx_setting` or `mspp_sitesetting`, rows where name ends in `/Certificate` | **CLMDiscoveryFlow_PowerPages** | App User in Power Pages env with read on Power Pages tables |
| **Custom domain SSL/TLS certs** (BYO uploaded via Power Platform admin center, like `pp-contoso.example.com` in the example) | Power Platform service backend (NOT in Dataverse) | **CLMDiscoveryFlow_PowerPagesAdmin** | Power Platform Administrator Entra role |
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
   ├── CLMDiscoveryFlow_PowerPages                          ← optional add-on
   │     covers IdP signing certs (Dataverse-side)
   │
   └── CLMDiscoveryFlow_PowerPagesAdmin                     ← optional add-on
         covers BYO custom domain SSL certs (BAP-side)
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
| 6 | Import `CLMDiscoveryFlow_PowerPages_1_0_0_3.zip` as **Update** | Solutions → Import |
| 7 | Bind both connection refs (`clm_dataverse` to CLM env, `clm_dataversepowerpages` to Power Pages env) | When prompted during import |
| 8 | Turn on the flow → Run on demand | Open flow → Turn on → Run |

### Schema probe behavior
Modern Power Pages schema (`mspp_*`) takes priority. Three outcomes:

| Probe result | What happens |
|---|---|
| `mspp_websites` reads OK | `PortalSchema` set to `modern`, flow uses `mspp_*` tables for the rest of the run |
| `mspp_websites` fails AND `adx_websites` reads OK | `PortalSchema` set to `legacy`, flow uses `adx_*` tables |
| Both fail | `PortalSchema` stays `unknown`, flow writes a `PowerPagesSchemaUnknown` event and terminates cleanly |

## Add-on 2: CLMDiscoveryFlow_PowerPagesAdmin (BYO SSL certs)

### What it does
1. Daily 02:45 AUS Eastern run
2. Calls the BAP admin API to list Power Pages sites in the configured env
3. For each site, fetches custom domain bindings + their attached SSL certs (thumbprint, expirationDate, issuer, type)
4. Upserts each cert as a `clm_credential` row with:
   - `clm_externalid = pp:custom:<envId>:<siteId>:<thumbprint>`
   - `clm_sourcesystem = 100000004` (Power Pages Site)
   - `clm_credentialtype = 200000001` (Certificate)
   - **`clm_expirydate` set from API** ✅ — unlike the IdP add-on, BAP returns parsed expiry
   - `clm_name` = `<site display name> - <hostname>` (e.g. `Contact - pp-contoso.example.com`)

This is the add-on that tracks the cert from the example screenshot.

### Required setup

| Step | What | Where |
|---|---|---|
| 1 | Grant Discovery SP the **Power Platform Administrator** Entra role | Entra admin center → Roles and admins → Power Platform Administrator → + Add assignments → pick the CLM Discovery app |
| 2 | Get the Power Pages **environment ID** (GUID, not URL) | Power Platform admin center → Environments → your Power Pages env → Settings → look for "Environment ID" |
| 3 | Set env variable `clm_powerpagesenvid` = the GUID from step 2 | Solutions → CLMDiscoveryFlowPowerPagesAdmin → + New → More → Environment variable → schema name `clm_powerpagesenvid` |
| 4 | Import `CLMDiscoveryFlow_PowerPagesAdmin_1_0_0_1.zip` | Solutions → Import. **Includes a new custom connector `clmbap`** |
| 5 | After import, open the **clmbap** custom connector → Security tab → paste the SP's Client Secret → Update connector | Custom connectors → clmbap → Security |
| 6 | Add the connector's Redirect URL to the AAD app's Authentication blade | Entra portal → App registrations → CLM Discovery app → Authentication |
| 7 | Create a **connection** for clmbap (sign in as the SP) | Connections → + New → search clmbap |
| 8 | Bind `clm_bap` connection reference to the new connection | Solutions → CLMDiscoveryFlowPowerPagesAdmin → Connection references |
| 9 | Turn on the flow → Run on demand | Open flow → Turn on → Run |

### API stability
The BAP custom domains endpoint is `2022-03-01-preview`. It's the API the Power Platform admin center UI uses today. Practical risk of API changes is low — it's been stable for 3+ years and Microsoft hasn't published a GA replacement. If it ever does change, the connector swagger needs updating; flow logic stays.

## Multi-environment Power Pages (future v25)

Both add-ons currently target **one** Power Pages env per import. Customers with prod + UAT + dev portals need to either:

| Approach | Setup |
|---|---|
| **A. Import the add-on N times into the CLM env** with different connection references (`clm_dataversepowerpages_prod`, `clm_dataversepowerpages_uat`, etc.) | Manual but works today. Add-on solution name needs renaming per copy. |
| **B. v25 — dynamic enumeration via BAP** | The BAP API enumerates all envs the SP can see. Future Discovery v25 would loop over `clm_sourceenvironment` rows of type `PowerPlatformEnvironment` and run both legs per env. Single import, scales. |
| **C. HTTP custom connector with dynamic URL** | Flow uses HTTP action with OAuth2 client_credentials against `<envUrl>/api/data/v9.2/...`. No connection refs needed per env. Most complex. |

Recommended path: ship today with **A** (single env per add-on import), build **B** when multi-env demand is concrete.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| IdP add-on creates `PowerPagesSchemaUnknown` event every run | SP doesn't have read on either schema's website table | Check the Application User's security role in the Power Pages env |
| IdP add-on succeeds but no credentials appear | No `*_sitesetting` rows match `endswith name '/Certificate'`. Tenant may use custom auth providers with different naming. | Inspect site settings manually — adjust the `endswith()` filter if your naming differs |
| BAP add-on returns 403 on List_Sites | SP missing Power Platform Administrator role | Grant role in Entra admin center → wait 5-10 min for token refresh → re-run |
| BAP add-on returns 200 but `For_each_Cert` body is empty | Site has no BYO SSL certs (uses default Microsoft-managed cert) | This is expected — Microsoft-managed certs aren't user-visible |
| Custom domain cert in CLM has wrong expiry | API returned different cert than what's bound (rare edge case with rotation in progress) | Re-run next day — it'll self-correct after rotation completes |

---

Back to [README](../README.md).
