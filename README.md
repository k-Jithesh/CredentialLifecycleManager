# Credential Lifecycle Manager — Dataverse schema

This folder contains everything needed to stand up the **CLM** Dataverse schema in your customer's Power Platform Premium environment.

## Contents

```
CredentialLifecycleManager/
├── schema_csv/                       # Human-readable schema reference
│   ├── 01_tables.csv
│   ├── 02_clm_credential_columns.csv
│   ├── 03_clm_discoveryrun_columns.csv
│   ├── 04_clm_renewalevent_columns.csv
│   ├── 05_clm_ownerrule_columns.csv
│   ├── 06_clm_sourceenvironment_columns.csv
│   ├── 07_option_sets.csv
│   ├── 08_relationships.csv
│   ├── 09_alternate_keys.csv
│   └── 10_security_roles.csv
├── solution/                         # Empty importable solution (publisher shell)
│   ├── solution.xml
│   ├── customizations.xml
│   └── [Content_Types].xml
├── solution_manifest.json            # Declarative spec for the deployment script
├── Deploy-CLMSchema.ps1              # Idempotent deployment via Dataverse Web API
└── README.md                         # This file
```

## Two deployment options

### Option A — Recommended: run the deployment script

Creates everything (publisher, solution, tables, columns, choices, relationships, alternate keys) via the Dataverse Web API. Idempotent — safe to re-run.

```powershell
# From this folder
pwsh ./Deploy-CLMSchema.ps1 -EnvironmentUrl https://YOUR-ORG.crm6.dynamics.com
```

Requirements:
- PowerShell 7+
- `Az.Accounts` (auto-installed if missing)
- The signing-in user must hold **System Customizer** or **System Administrator** in the target Dataverse environment.

The script will:
1. Sign you in interactively to Azure AD.
2. Acquire a Dataverse token for the supplied environment URL.
3. Create the `clmpublisher` publisher.
4. Create the `CredentialLifecycleManager` (unmanaged) solution.
5. Create the 8 global option sets.
6. Create the 5 tables and their columns.
7. Create the 9 relationships (lookups to user/team/credential/sourceenvironment).
8. Create the 2 alternate keys for upsert.

Security roles are not created by the script — they're easier and safer to create in the maker portal using `schema_csv/10_security_roles.csv` as the reference.

### Option B — Import the empty solution, then run the script

If you must demonstrate a solution import in the UI first, zip the `solution/` folder contents into `CredentialLifecycleManager.zip`, import it via **Solutions > Import**, then run `Deploy-CLMSchema.ps1`. The script will detect the existing solution and only add tables/columns to it.

```powershell
Compress-Archive -Path solution/* -DestinationPath CredentialLifecycleManager.zip -Force
```

## Object-naming conventions

| Object        | Convention                | Example                              |
|---------------|---------------------------|--------------------------------------|
| Publisher prefix | `clm`                  | `clm_credential`                     |
| Option set    | `clm_<purpose>`           | `clm_sourcesystem`                   |
| Table         | `clm_<noun>`              | `clm_credential`                     |
| Lookup column | `clm_<role>`              | `clm_owneruser`, `clm_environmentref`|
| Alternate key | `clm_<table>_<col>_key`   | `clm_credential_externalid_key`      |

## What the schema covers

- **`clm_credential`** — one row per discovered secret/cert/key. Upsert via `clm_externalid`.
- **`clm_sourceenvironment`** — scopes that discovery flows scan (PP envs, Azure subs, tenants, Key Vaults).
- **`clm_coveragegap`** — every scope the discovery identity could **not** enumerate, with HTTP status, error detail, auto-generated remediation hint and triage state. Closes the "silent miss" hole: a vault we can't read still shows up.
- **`clm_discoveryrun`** — audit log of each discovery flow execution.
- **`clm_renewalevent`** — append-only history (Discovered, ReminderSent, Claimed, Renewed, …).
- **`clm_ownerrule`** — regex-based fallback owner assignment when source has no owner set.

See **`docs/RBAC_AND_COVERAGE.md`** for the full RBAC matrix the Discovery SP needs and how each missing permission maps to a `clm_coveragegap` row.

See **`docs/DISCOVERY_FLOW_PATTERN.md`** for the canonical discovery-flow pseudocode and a drop-in Power Automate JSON sketch implementing the gap-upsert pattern.

## Notes on the calculated column

`clm_daysuntilexpiry` is intentionally **not** created by the script — Dataverse calculated columns can't be defined cleanly via the Web API in this version. Add it via the maker portal after import:

- Table: `Credential`
- New column → Data type **Whole Number**, Behaviour **Calculated**
- Formula: `DiffInDays(Now(), clm_expirydate)`
- If using Formula data type, use - `DateDiff('Expiry Date', Now(),TimeUnit.Days)`

## Next steps after schema deployment

1. Create the 3 security roles from `schema_csv/10_security_roles.csv`.
2. Provision the AAD app registration for the **CLM Graph & Azure** custom connector (cert auth).
3. Import the custom connector (separate deliverable).
4. Import the 6 discovery cloud flows + reminder engine flow + owner-resolver child flow (separate deliverable).
5. Import the model-driven app `Credential Lifecycle` (separate deliverable).
6. Seed `clm_sourceenvironment` with the scopes to scan and `clm_ownerrule` with starter rules.
