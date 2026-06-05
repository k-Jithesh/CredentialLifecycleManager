# CLM Discovery Identity — RBAC reference

The Credential Lifecycle Manager (CLM) discovery flows authenticate as a single AAD service principal (the **Discovery SP**) via certificate auth held in Key Vault. Coverage of the inventory depends entirely on what this SP can see.

This document is the canonical list of permissions to request, and the failure modes you get when each is missing — which is exactly what the `clm_coveragegap` table captures.

---

## 1. Microsoft Graph (application permissions)

| Permission | What it enables | Failure mode if missing |
|---|---|---|
| `Application.Read.All` | List `applications` + `servicePrincipals`, read `passwordCredentials` / `keyCredentials` / `owners` | 403 on `/applications` → gap rows of type `EntraTenant / NoListPermission` |
| `Directory.Read.All` | Resolve owners to user objects, read `/users/{id}/manager` for escalation | Owner stays unresolved → `clm_credential.clm_status = Orphaned` (not a coverage gap, by design — it's a *known* credential) |
| `AuditLog.Read.All` | Creator fallback for apps with no owners set | Owner resolution falls through to ownerRule / Orphaned |

Admin consent required.

---

## 2. Azure ARM (management plane)

Assign **at the highest scope you can negotiate**, in order of preference:

| Scope | Role | What it unlocks |
|---|---|---|
| **Tenant root management group** | `Reader` | Enumerate every subscription + every resource type via Azure Resource Graph |
| **Each subscription** (fallback) | `Reader` | Enumerate resources in that subscription only |
| **Specific resource groups** (least preferred) | `Reader` | Enumerate within the RG only — guarantees blind spots |

**Failure → gap rows:**

| Symptom | HTTP | `clm_gaptype` |
|---|---|---|
| Resource Graph query returns 403 | 403 (`AuthorizationFailed`) | `ManagementGroup / NoListPermission` |
| `GET /subscriptions/{sub}/resources` returns 403 | 403 | `AzureSubscription / NoListPermission` |
| Subscription not visible at all | n/a — missing from list | Detected by tenant-root scan vs subscription scan diff (see Coverage Probe below) |

---

## 3. Azure Key Vault (data plane)

Management-plane access (above) only tells you the vault **exists**. Reading secret/cert expiry dates requires data-plane access. Two models:

### RBAC mode (recommended for new vaults)

| Role | Scope | Purpose |
|---|---|---|
| `Key Vault Reader` | each vault (or RG/sub) | Lists secret/cert objects + metadata |
| `Key Vault Secrets User` | each vault | Read secret properties incl. `expires` |
| `Key Vault Certificate User` | each vault | Read certificate properties |

### Access-policy mode (legacy vaults)

Add the Discovery SP to each vault's access policies with **List + Get** on Secrets and Certificates.

**Failure → gap rows:**

| Symptom | HTTP | `clm_gaptype` |
|---|---|---|
| Vault data-plane returns 403 `Forbidden` | 403 | `KeyVault / NoReadPermission` |
| Vault network ACLs deny | 403 `ForbiddenByFirewall` | `KeyVault / NetworkBlocked` |
| Vault soft-deleted | 404 | `KeyVault / NotFound` |
| Vault behind private endpoint only | timeout / 403 | `KeyVault / NetworkBlocked` |

The Discovery SP **must** be either on the vault's allow-list of trusted IPs, or call from a subnet with a service endpoint / private endpoint to the vault. The flow records the failure mode so the network team can act.

---

## 4. Power Platform

| Where | How to grant | What it unlocks |
|---|---|---|
| **Power Platform admin** | Add SP via `Add-PowerAppsAccount` + `Set-AdminPowerAppRoleAssignment`, or assign the `Power Platform Administrator` directory role | List environments, custom connectors, connection references via BAP API |
| **Each Dataverse environment** | Create an **Application User** with `System Reader` plus a CLM-specific `CLM Discovery` security role (read on app users, email server profiles, plugin assemblies) | Enumerate per-environment Dataverse credentials |

**Failure → gap rows:**

| Symptom | `clm_gaptype` |
|---|---|
| BAP returns 403 listing environments | `EntraTenant / NoListPermission` |
| Specific environment returns 401 from Dataverse Web API | `DataverseEnvironment / NoReadPermission` |
| Environment is in admin mode / disabled | `DataverseEnvironment / Disabled` |

---

## 5. Other Azure resource types

For completeness — each is its own data-plane permission set:

| Resource | Role |
|---|---|
| API Management | `API Management Service Reader Role` |
| Service Bus | `Azure Service Bus Data Reader` |
| Storage | `Reader and Data Access` (to read keys metadata; do NOT request the key value itself) |
| App Configuration | `App Configuration Reader` |

---

## 6. The "Coverage Probe" technique

Two independent enumerations are run and **diffed** weekly:

1. **Wide probe** — Azure Resource Graph query at tenant-root scope:
   `resources | where type =~ 'microsoft.keyvault/vaults' | project id, subscriptionId, name`
2. **Deep probe** — per-subscription ARM list + per-vault data-plane list (what the daily discovery already does)

Anything in (1) but not in (2) → a coverage gap is opened with the most specific failure type the deep probe encountered. Anything in (2) but not in (1) → indicates the SP has weird scope assignments; flagged for the platform team.

If Resource Graph itself is denied at the tenant root → a single top-level gap is opened (`ManagementGroup / NoListPermission`) with a clear resolution hint, because at that point we cannot even count what we don't see.

---

## 7. Hardening / hygiene

- Discovery SP authenticates with **certificate** only — no client secret. Cert is rotated via Key Vault auto-rotation (CLM eats its own dog food).
- Discovery SP has **no write** permissions anywhere. All write actions in the customer's tenant are performed by humans clicking on Teams Adaptive Cards inside their own delegated context.
- Discovery SP is **excluded from Conditional Access policies that require interactive MFA**, but **included in policies requiring trusted IP + workload identity federation**.
- All discovery flows log `clm_discoveryrun` rows including the SP's `oid` and source IP for audit.
