# Discovery flow — coverage-gap pattern

Every CLM discovery flow follows the same pattern: try to enumerate, and if it can't, record exactly *why* in `clm_coveragegap`. Below is the canonical pseudocode plus a ready-to-adapt JSON sketch of the failure-handling block, and an HTTP→gaptype mapping table.

---

## Canonical pseudocode (applies to every source)

```text
Recurrence trigger (daily at 02:00 user TZ)
└─ Create clm_discoveryrun row { startedOn = utcNow(), status = Running }
└─ List all clm_sourceenvironment WHERE clm_isenabled = true AND scopeType matches this flow

   For each scope:
       try Stage1 = enumerate top-level objects in scope (ARM list / Graph list / BAP list)
       on success:
           For each object:
               try Stage2 = read credential details (data-plane)
               on success:
                   Upsert clm_credential by clm_externalid
               on failure:
                   Upsert clm_coveragegap by externalId = '{scopeType}|{objectId}'
                       gapType         = mapHttpToGapType(status, errorCode)
                       lastHttpStatus  = status
                       lastErrorCode   = errorCode
                       lastErrorDetail = body (truncated 4000)
                       lastAttemptedOn = utcNow()
                       consecutiveFailures = coalesce(prev, 0) + 1
                       resolutionHint  = buildHint(scopeType, gapType, discoverySpAppId)
                       severity        = computeSeverity(scopeType, isProduction)
                       status          = case prev.status when 'Suppressed' then 'Suppressed'
                                                          when 'Acknowledged' then 'Acknowledged'
                                                          else 'Open'
                       firstDetectedOn = coalesce(prev.firstDetectedOn, utcNow())

       on Stage1 failure:
           Upsert clm_coveragegap by externalId = '{scopeType}|{scopeId}'   (one big gap for the whole scope)
           with the same shape as above.
           Skip Stage2 for this scope.

       On scope-level success after a previous failure:
           Update clm_coveragegap SET status='Resolved', resolvedOn=utcNow(), consecutiveFailures=0
           where externalId='{scopeType}|{scopeId}' AND status IN ('Open','Acknowledged')

└─ Update clm_discoveryrun { finishedOn, status (Succeeded / PartialSuccess / Failed),
                              foundCount, createdCount, updatedCount, orphanedCount, errorCount }
```

---

## HTTP → `clm_gaptype` mapping (used by `mapHttpToGapType`)

| HTTP / signal | Error code patterns | `clm_gaptype` |
|---|---|---|
| 401 | any | `AuthFailed` |
| 403 | `AuthorizationFailed`, `Forbidden`, `InsufficientPermissions` | `NoReadPermission` (or `NoListPermission` for management-plane) |
| 403 | `ForbiddenByFirewall`, `ForbiddenByRbac` + network reason, `ConditionalAccessFailed` | `NetworkBlocked` |
| 404 | `ResourceNotFound`, `NotFound`, soft-deleted | `NotFound` |
| 409 | `ResourceDisabled`, `EnvironmentInAdminMode` | `Disabled` |
| 429 (after retry budget exhausted) | `TooManyRequests`, `Throttled` | `ThrottledMaxRetries` |
| Network timeout / SSL handshake fail | n/a | `NetworkBlocked` |
| Token call failed (MSAL error AADSTS50xxxx) | n/a | `AuthFailed` |
| anything else | n/a | `UnknownError` |

Differentiating `NoListPermission` vs `NoReadPermission`: if the failed call was the *outer* list (Stage 1) → `NoListPermission`; if the failed call was the *per-object* read (Stage 2) → `NoReadPermission`.

---

## `buildHint(scopeType, gapType, spAppId)` — sample outputs

```text
KeyVault / NoReadPermission     → "Grant 'Key Vault Reader' + 'Key Vault Secrets User' to service principal {spAppId}
                                   on vault {scopeName} (id: {scopeId}). Run:
                                     az role assignment create --assignee {spAppId} \
                                       --role 'Key Vault Reader' --scope {scopeId}"

KeyVault / NetworkBlocked       → "Vault {scopeName} firewall denied the request. Either add the CLM discovery
                                   IP range (see CLM Ops runbook) to vault networking → firewalls and virtual
                                   networks, or attach a private endpoint reachable from the CLM subnet."

AzureSubscription / NoListPermission → "Grant 'Reader' to service principal {spAppId} on subscription {scopeName}
                                        (id: {scopeId}) or on the parent management group."

EntraTenant / NoListPermission  → "Grant Microsoft Graph application permission 'Application.Read.All' to
                                   service principal {spAppId} and provide tenant admin consent."

DataverseEnvironment / NoReadPermission → "Create an Application User for app id {spAppId} in environment
                                           {scopeName} and assign the 'CLM Discovery' security role."
```

These strings end up in `clm_coveragegap.clm_resolutionhint` and are surfaced verbatim in the Teams Adaptive Card sent to the owner.

---

## Power Automate flow — failure-handling JSON sketch

This is the "Scope" container that wraps the data-plane read. Drop it into any discovery flow's per-object loop. Replace `@{items('Apply_to_each_vault')...}` with the equivalent expressions for your source.

```json
{
  "type": "Scope",
  "actions": {
    "Read_secrets": {
      "type": "OpenApiConnection",
      "inputs": {
        "host": { "connectionName": "shared_clmgraphazure", "operationId": "ListKeyVaultSecrets" },
        "parameters": { "vaultName": "@{items('Apply_to_each_vault')?['name']}" }
      },
      "runtimeConfiguration": {
        "retryPolicy": { "type": "exponential", "count": 4, "interval": "PT10S", "maximumInterval": "PT2M" }
      }
    },
    "Upsert_each_secret": {
      "type": "Foreach",
      "foreach": "@outputs('Read_secrets')?['body/value']",
      "actions": { "_comment": "Calls clm_credential UpdateRecord with alternate key clm_credential_externalid_key" },
      "runAfter": { "Read_secrets": [ "Succeeded" ] }
    },
    "Resolve_prior_gap_if_any": {
      "type": "OpenApiConnection",
      "inputs": {
        "host": { "connectionName": "shared_commondataserviceforapps", "operationId": "UpdateRecord" },
        "parameters": {
          "entityName": "clm_coveragegaps",
          "recordId": "clm_coveragegap_externalid_key='@{concat('KeyVault|', items('Apply_to_each_vault')?['id'])}'",
          "item/clm_status": 950000002,
          "item/clm_resolvedon": "@{utcNow()}",
          "item/clm_consecutivefailures": 0
        }
      },
      "runAfter": { "Read_secrets": [ "Succeeded" ] }
    }
  },
  "runAfter": {}
},
{
  "type": "Scope",
  "actions": {
    "Compose_http_status": {
      "type": "Compose",
      "inputs": "@coalesce(outputs('Read_secrets')?['statusCode'], result('Scope')[0]?['outputs']?['statusCode'], 0)"
    },
    "Compose_error_body": {
      "type": "Compose",
      "inputs": "@substring(coalesce(string(body('Read_secrets')), string(result('Scope')[0]?['outputs']?['body']), ''), 0, min(4000, length(coalesce(string(body('Read_secrets')), string(result('Scope')[0]?['outputs']?['body']), ''))))"
    },
    "Compose_gap_type": {
      "type": "Compose",
      "inputs": "@if(equals(outputs('Compose_http_status'), 403), if(contains(toLower(outputs('Compose_error_body')), 'firewall'), 900000002, 900000001), if(equals(outputs('Compose_http_status'), 401), 900000004, if(equals(outputs('Compose_http_status'), 404), 900000006, if(equals(outputs('Compose_http_status'), 429), 900000005, 900000007))))"
    },
    "Compose_external_id": {
      "type": "Compose",
      "inputs": "@concat('KeyVault|', items('Apply_to_each_vault')?['id'])"
    },
    "Compose_resolution_hint": {
      "type": "Compose",
      "inputs": "@concat('Grant Key Vault Reader + Key Vault Secrets User to SP ', variables('discoverySpAppId'), ' on vault ', items('Apply_to_each_vault')?['name'], ' (', items('Apply_to_each_vault')?['id'], ').')"
    },
    "Upsert_coverage_gap": {
      "type": "OpenApiConnection",
      "inputs": {
        "host": { "connectionName": "shared_commondataserviceforapps", "operationId": "UpdateRecord" },
        "parameters": {
          "entityName": "clm_coveragegaps",
          "recordId": "clm_coveragegap_externalid_key='@{outputs('Compose_external_id')}'",
          "item/clm_name": "@{concat('KeyVault - ', items('Apply_to_each_vault')?['name'])}",
          "item/clm_externalid": "@{outputs('Compose_external_id')}",
          "item/clm_scopetype": 800000003,
          "item/clm_scopename": "@{items('Apply_to_each_vault')?['name']}",
          "item/clm_scopeid": "@{items('Apply_to_each_vault')?['id']}",
          "item/clm_parentscopeid": "@{items('Apply_to_each_vault')?['subscriptionId']}",
          "item/clm_gaptype": "@{outputs('Compose_gap_type')}",
          "item/clm_status": 950000000,
          "item/clm_lastattemptedon": "@{utcNow()}",
          "item/clm_lasthttpstatus": "@{outputs('Compose_http_status')}",
          "item/clm_lasterrordetail": "@{outputs('Compose_error_body')}",
          "item/clm_resolutionhint": "@{outputs('Compose_resolution_hint')}",
          "item/clm_firstdetectedon": "@{utcNow()}"
        }
      },
      "_comment": "Behaviour: Dataverse Upsert via alternate key — creates the row if it doesn't exist, updates it if it does."
    },
    "Increment_failure_counter": {
      "type": "OpenApiConnection",
      "inputs": {
        "host": { "connectionName": "shared_commondataserviceforapps", "operationId": "PerformUnboundAction" },
        "parameters": {
          "actionName": "clm_IncrementGapCounter",
          "parameters/ExternalId": "@{outputs('Compose_external_id')}"
        }
      },
      "_comment": "Small custom action that increments clm_consecutivefailures by 1 atomically and sets firstDetectedOn only if null. Avoids read-modify-write race when many gaps are upserted in parallel.",
      "runAfter": { "Upsert_coverage_gap": [ "Succeeded" ] }
    }
  },
  "runAfter": { "Scope": [ "Failed", "Skipped", "TimedOut" ] }
}
```

Notes on this sketch:
- The whole thing relies on the **alternate key** `clm_coveragegap_externalid_key` created by the deploy script. Upsert via alternate key is the only race-safe way to do "create or update by business key" in Dataverse cloud flows.
- The error-body Compose truncates to 4000 chars to fit `clm_lasterrordetail`.
- The `Resolve_prior_gap_if_any` action in the success path is what auto-closes gaps once access is restored — without it the table fills with stale "Open" rows.
- For sources that return multi-status responses (e.g. Graph batch), wrap the per-item handling inside an inner scope so each item gets its own gap row.

---

## Stage-1 (scope-level) gap shape

When the *outer* list fails (e.g. ARM `/subscriptions/{sub}/resources` returns 403), the upsert payload is structurally identical but uses the subscription itself as the scope:

```json
{
  "item/clm_externalid":  "AzureSubscription|{subId}",
  "item/clm_scopetype":   800000001,
  "item/clm_scopename":   "{sub displayName}",
  "item/clm_scopeid":     "{subId}",
  "item/clm_gaptype":     900000000,
  "item/clm_resolutionhint": "Grant 'Reader' to SP {appId} on subscription {subName} or its parent management group."
}
```

One row covers the whole subscription — Stage 2 is skipped for that scope entirely. The dashboard then makes it impossible to mistake "no credentials found" for "no credentials exist."

---

## Weekly Coverage Probe flow (separate flow)

Runs once a week, in addition to the daily discovery flows. Uses Azure Resource Graph (the "wide probe") to list every Key Vault and Power Platform environment in the tenant, then diffs against what daily discovery saw. The diff produces gap rows even for scopes that daily discovery never even attempted (because the SP can't see them in the first place).

```text
1. Query Resource Graph at tenant root:
     resources | where type =~ 'microsoft.keyvault/vaults'
              | project id, subscriptionId, name, resourceGroup, location
2. For each vault in the wide-probe result:
     If no clm_credential rows AND no clm_coveragegap rows reference this scopeId
     → upsert clm_coveragegap (scopeType=KeyVault, gaptype=NoReadPermission, resolutionHint='Daily discovery never reached this vault. Grant Key Vault Reader + Secrets User to SP {appId}.')
3. Same pattern for PP environments via PP Admin BAP API.
4. If Resource Graph itself returns 403:
     → upsert single clm_coveragegap (scopeType=ManagementGroup, gaptype=NoListPermission)
     → also raise a Sev2 Teams alert to Platform Ops because at this point coverage cannot be measured.
```
