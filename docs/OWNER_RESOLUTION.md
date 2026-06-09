# Owner Resolution — how credentials get owners

The CLM **OwnerResolver** flow runs daily and decides who owns each discovered credential. Ownership drives reminders, escalations, and triage views. This doc explains the resolution order, the rule engine, and how to write rules that actually match.

## Resolution priority (per credential, every day)

```
┌─────────────────────────────────────────────────────────────┐
│  Is clm_ownerlocked = Yes on the credential?                │
│  ─► YES  →  skip. Owner field is sacred. Manual edits win.  │
│  ─► NO   →  continue                                        │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  PHASE 1 — Tag-driven (source of truth)                     │
│                                                             │
│  Is clm_ownertag a valid email AND resolves to a            │
│  Dataverse user?                                            │
│  ─► YES  →  Set Owner User, clm_ownersource = Tag           │
│             Write OwnerFromTag renewal event                │
│             STOP                                            │
│  ─► email but didn't resolve →                              │
│       Write OrphanedFromTag event (visible in audit)        │
│  ─► no tag, non-email, or empty → continue                  │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  PHASE 2 — Stale tag cleanup                                │
│                                                             │
│  Was clm_ownersource previously Tag, AND the tag is now     │
│  invalid (empty / non-email / unresolvable)?                │
│  ─► YES  →  Clear Owner User + clm_ownersource              │
│             Write TagOwnerCleared event                     │
│             Continue to Phase 3 to potentially re-assign    │
│  ─► NO   →  continue                                        │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  PHASE 3 — Rule fallback                                    │
│                                                             │
│  Only runs if owner is currently empty.                     │
│  Evaluates clm_ownerrule rows in clm_priority asc order.    │
│  First rule that matches wins.                              │
│  ─► match  →  Set Owner User or Owner Team,                 │
│               clm_ownersource = Rule                        │
│               Write OwnerFromRule renewal event             │
│  ─► no match  →  credential stays unowned                   │
└─────────────────────────────────────────────────────────────┘
```

The credential's `clm_ownersource` field (Tag / AADOwner / Rule / Manual) tells you which phase set the current owner. The `clm_renewalevent` timeline shows the history of every change.

## Where the tag comes from

Discovery v17+ captures the owner identifier from:

| Source system | Discovery action | Stored in `clm_ownertag` |
|---|---|---|
| Key Vault secret | Reads vault's `tags.Owner` (case variations: `Owner`, `owner`, `OwnerEmail`) | The tag value, lowercased |
| AAD App Registration (secret/cert) | Calls `GET /applications/{id}/owners` → first owner's `userPrincipalName` | The UPN, lowercased |
| Enterprise Application / Service Principal | not currently captured (connector lacks `ListServicePrincipalOwners`) | empty — rules must drive ownership |

Tags propagate automatically on the **next** Discovery + Resolver run after a change. Typical end-to-end delay is one day.

## The rule engine in detail

`clm_ownerrule` rows are stored in Dataverse. Each row defines:

| Field | Type | Meaning |
|---|---|---|
| `clm_name` | Text | Friendly name, used as upsert key by `Seed-CLMOwnerRules.ps1` |
| `clm_priority` | Whole Number | Lower wins. Evaluated ascending. Use 10, 20, 30, … so you can insert between later. |
| `clm_isactive` | Yes/No | Inactive rules are silently skipped |
| `clm_matchscope` | Choice | What credential field to match against (see scope table below) |
| `clm_matchpattern` | Text (max 500) | Case-insensitive substring (NOT regex — see notes) |
| `clm_assigntouser` | Lookup → User | If set, this user becomes the owner |
| `clm_assigntoteam` | Lookup → Team | If set, this team becomes the owner team |
| `clm_matchcount` | Whole Number | Auto-incremented every time the rule fires |
| `clm_lastmatchedon` | DateTime | Last time the rule fired (helpful for cleanup) |

A rule can set user OR team OR both (both = primary owner is the user, team co-owns for visibility).

### Match scopes

| Scope choice (value) | What it evaluates | Example pattern |
|---|---|---|
| `DisplayName` (700000000) | `clm_displayname` (typically the source object's display name) | `at-` matches `AT-Integration-Prod` |
| `Environment` (700000002) | `clm_environment` (subscription id, tenant label, etc.) | `prod` matches `contoso.com - <tenant-guid>` if it contains "prod" |
| `KeyVaultName` (700000003) | First segment of `clm_displayname` before `/` (KV credentials only — they're stored as `vault/secret`) | `-prod-` matches `kv-prod-team1` |
| `Tag` (700000001) | NOT implemented (Discovery doesn't capture custom tags into a dedicated column yet) | n/a — use Environment or DisplayName |
| `ResourceGroup` (700000004) | NOT implemented (Discovery doesn't capture RG into a dedicated column yet) | n/a |

If a rule's scope is unsupported, the resolver silently skips it (no error).

### Pattern matching — limitations

- **Case-insensitive substring**, not regex. Power Automate has no regex engine.
- Empty pattern (`""`) matches everything — useful for a catch-all rule with `priority = 999`.
- No anchors (`^`, `$`), no character classes, no wildcards — just plain substring.

If you need regex, the resolver flow would have to call out to an Azure Function. Out of scope for v1.

## Writing rules — practical patterns

### Pattern A — Prefix-based ownership
Most common. Credentials are named with a prefix indicating the team that owns them.

```
Priority | Scope        | Pattern   | Assign To Team          | Comment
---------|--------------|-----------|-------------------------|----------------
   10    | DisplayName  | clm-      | (you, user)             | Self-owned dev work
   20    | DisplayName  | at-       | AT Integration Team     | AT prefix
   30    | DisplayName  | crm-      | D365 Ops                | CRM prefix
   40    | DisplayName  | sap-      | SAP Integration         | SAP prefix
```

### Pattern B — Environment-based escalation
Production gets routed to the on-call team regardless of who built it.

```
Priority | Scope        | Pattern   | Assign To Team    | Comment
---------|--------------|-----------|-------------------|----------------
   50    | Environment  | prod      | Platform Ops      | Anything tagged prod
   60    | Environment  | uat       | UAT Owners        | Anything tagged uat
```

### Pattern C — Key Vault co-location
Vaults named per team — all secrets in that vault go to that team.

```
Priority | Scope         | Pattern   | Assign To Team       | Comment
---------|---------------|-----------|----------------------|----------------
   70    | KeyVaultName  | kv-data   | Data Engineering     | Data team's vaults
   80    | KeyVaultName  | kv-int    | Integration Team     | Integration vaults
```

### Pattern D — Catch-all
Any credential that didn't match any rule above lands on ops.

```
Priority | Scope        | Pattern   | Assign To Team    | Comment
---------|--------------|-----------|-------------------|----------------
  999    | DisplayName  |  (empty)  | Platform Ops      | Catch-all
```

## Seeding rules with the script

[`Seed-CLMOwnerRules.ps1`](../Seed-CLMOwnerRules.ps1) takes a `$Rules` array at the top of the script and upserts each by name. Edit the array, then:

```powershell
pwsh ./Seed-CLMOwnerRules.ps1 -EnvironmentUrl https://<DATAVERSE_HOST> -WhatIf  # preview
pwsh ./Seed-CLMOwnerRules.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>          # apply
```

The script resolves user emails → `systemuserid` and team names → `teamid` against the target environment. Rules whose user/team can't be resolved are skipped with a warning.

Re-running is safe — existing rules with the same `Name` get PATCHed in place.

## How to validate rule quality

Two views are built into the model-driven app:

1. **Active Rules (by Priority)** — shows match count per rule. Rules with 0 matches after a week are usually misconfigured (wrong scope or pattern).
2. **Orphans (No Owner)** — credentials that no rule and no tag matched. Use these to identify gaps in your rule set.

You can also query the Renewal Events timeline for `OwnerFromRule -` events to see exactly which rule fired for each credential.

## Locking an owner against auto-reassignment

Set `clm_ownerlocked = true` on the credential row (via the model-driven app form). Both Owner Resolver and Tag-driven reassignment will skip the row entirely. Useful for:
- Credentials with a legally-mandated specific owner
- Service accounts where automatic reassignment would break workflows
- Long-lived team-owned credentials where individual rotation matters

## Tuning checklist

After two weeks of running:
- [ ] Open **Orphans (No Owner)** view → are there obvious patterns? Add rules for them.
- [ ] Open **Active Rules (by Priority)** view → any rules with match count = 0? Either inactive them, or refine the pattern.
- [ ] Open **Failures (Orphaned / Reminder Failed)** in Renewal Events → look for `OrphanedFromTag` events. The tag email isn't a Dataverse user — either invite them, or replace the tag with someone who is.
- [ ] Check tag adoption rate — what % of KV credentials have `clm_ownertag` populated? If low, push for Azure tag governance.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Resolver completes but no owners get set | Are any rules `clm_isactive = true`? Is the SP running the flow able to write to `clm_credential` and `clm_ownerrule`? |
| Same rule fires for every credential | Pattern is too generic. Add scope constraint or narrow the pattern. |
| Tag user resolves but the wrong person becomes owner | Tag value typoed in Azure. Fix at source — next discovery propagates it. |
| Manually-set owner keeps being overwritten | Set `clm_ownerlocked = true` to protect manual edits. |
| `OrphanedFromTag` events piling up | Bad tag values. Either fix the tag in Azure or create a rule that overrides the tag-driven assignment for those credentials. |

---

Back to [README](../README.md).
