# Discovery flow — `Discovery-CLMCredentials`

Daily scheduled Cloud Flow that pulls AAD app credentials + Key Vault secret metadata via the CLM custom connectors and upserts into `clm_credential`, emitting `clm_renewalevent` rows for items within the renewal window.

## Files

| File | Purpose |
|---|---|
| `definition.json` | Logic Apps / Power Automate workflow definition (the `properties.definition` body). |
| `manifest.json`   | Connection references and environment variables the flow consumes. |

## Flow shape

```
Recurrence (daily 02:00 AEST)
├─ Init RenewalWindowDays (30)
├─ Init DiscoveryRunId    (guid)
├─ Graph_Leg (Scope)
│   └─ ListApplications
│       └─ For each app
│           ├─ For each passwordCredential → Upsert clm_credential + (if expiring) Create clm_renewalevent
│           └─ For each keyCredential       → Upsert clm_credential + (if expiring) Create clm_renewalevent
├─ ARM_Leg   (Scope)
│   └─ ListSubscriptions
│       └─ For each sub
│           └─ ListKeyVaults
│               └─ For each vault
│                   └─ ListVaultSecrets
│                       └─ For each secret → Upsert + (if expiring) Create renewal event
├─ Handle_Graph_Leg_Failure  (runs only on Graph_Leg Failed/TimedOut → DiscoveryFailed event)
└─ Handle_ARM_Leg_Failure    (runs only on ARM_Leg Failed/TimedOut   → DiscoveryFailed event)
```

## Required schema (assumed)

`clm_credential` must have an **alternate key** on `clm_externalid` so the `UpsertRecord` action targets the right row.

Columns referenced:
- `clm_externalid` (string, alternate key) — e.g. `aad:app:<appId>:secret:<keyId>`, `kv:<vaultId>:secret:<name>`
- `clm_displayname` (string)
- `clm_type` (choice: `AadAppSecret`, `AadAppCertificate`, `KeyVaultSecret`, `ManagedIdentity`)
- `clm_expiresat` (datetime)
- `clm_sourceuri` (string)
- `clm_lastdiscoveredat` (datetime)
- `clm_discoveryrunid` (string)

`clm_renewalevent` columns referenced:
- `clm_eventtype` (choice: `DiscoveryDetected`, `DiscoveryFailed`, `NotificationSent`, `Renewed`)
- `clm_eventtimeutc` (datetime)
- `clm_summary` (string)
- `clm_payloadjson` (multiline string)
- `clm_discoveryrunid` (string)

If your logical names differ, search-replace in `definition.json`.

## Import (two paths)

### Path A — paste into a new solution-aware flow (fastest)

1. `make.powerautomate.com` → **Solutions** → your CLM solution → **+ New** → **Automation** → **Cloud flow** → **Scheduled**.
2. Name it `Discovery-CLMCredentials`, set Recurrence Daily at 02:00, **Create**.
3. Open the flow → top right **⋯** → **Edit** → top-right **⋯** → **Peek code** doesn't allow paste; instead use the **Save As Template** / direct JSON edit path: open the flow URL, append `/edit` and switch to **Code view** in the new designer (available in the maker portal previews).
4. Replace the definition with `definition.json`.
5. Authorize the three connections (CLM Graph Discovery, CLM Azure Discovery, Dataverse).

### Path B — pack into a solution and import via `pac` CLI (repeatable)

1. Place `definition.json` inside a `Workflows\<guid>.json` envelope inside an unmanaged solution zip (see `..\..\Deploy-CLMDiscoveryFlow.ps1` for scaffolding).
2. `pac solution import --path .\solution.zip --activate-plugins`.

Run `..\..\Deploy-CLMDiscoveryFlow.ps1 -EnvironmentUrl https://<org>.crm6.dynamics.com` to do this automatically.

## Validate

1. Open the flow → **Test** → **Manually** → **Run flow**.
2. Check **Run history** — every action should be green.
3. In the model-driven app (or via Dataverse REST), confirm:
   - New rows in `clm_credentials` with `clm_lastdiscoveredat = today`.
   - New rows in `clm_renewalevents` with `clm_eventtype = DiscoveryDetected` for any credentials within 30 days of expiry.

## Next phase

After this flow is green, build the **Phase 3 notification flow** that scans `clm_credential` daily, resolves owners via `clm_ownerrule`, and sends Teams + email — and creates `clm_renewalevent` of type `NotificationSent`.
