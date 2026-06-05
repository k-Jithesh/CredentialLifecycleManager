# CLM custom connectors (Graph + ARM)

Power Platform custom connectors are single-host. CLM ships **two** connectors that share the same Discovery AAD app + certificate:

| Connector | Host | Scope | Operations |
|---|---|---|---|
| **CLM Graph Discovery** | `graph.microsoft.com` | `https://graph.microsoft.com/.default` | `ListApplications`, `GetApplication`, `ListServicePrincipals`, `ListApplicationOwners` |
| **CLM Azure Discovery** | `management.azure.com` | `https://management.azure.com/.default` | `ListSubscriptions`, `ListResources`, `ListKeyVaults`, `ListVaultSecrets`, `ListUserAssignedIdentities` |

## Files

| File | Purpose |
|---|---|
| `apiDefinition.graph.swagger.json` | OpenAPI 2.0 — Graph operations. |
| `apiDefinition.arm.swagger.json`   | OpenAPI 2.0 — ARM operations. |
| `apiProperties.graph.json`         | Cert-auth connection + Graph `ConsistencyLevel: eventual` header policy. |
| `apiProperties.arm.json`           | Cert-auth connection (ARM scope). |
| `settings.graph.json`              | paconn settings (Graph). |
| `settings.arm.json`                | paconn settings (ARM). |
| `icon.png`                         | Optional connector tile icon. |

## Auth

Power Platform custom connectors **do not allow** AAD certificate auth (that identity provider is 1st-party only). Both connectors use the supported `aad` identity provider with a **client secret** generated against the CLM Discovery app. The secret is stored on the connector at deploy time; users provide no secret when creating connections — they just sign in.

The certificate from `Register-CLMDiscoveryApp.ps1` remains on the Discovery app for non-connector consumers (PowerShell, Azure Functions, custom workers).

> **Delegated, not app-only.** Connections use the signed-in user's token. For unattended Cloud Flows, create the connection under a service account that has the consented Graph/Azure permissions.

## Deploy both connectors

```powershell
..\Deploy-CLMConnector.ps1 `
    -DiscoveryAppId <appId from Register-CLMDiscoveryApp.ps1> `
    -EnvironmentId  <Power Platform env GUID>
```

Deploy a single connector with `-Only graph` or `-Only arm`. For updates, capture the connector ids printed by paconn and pass them via `-GraphConnectorId` / `-ArmConnectorId`.

## Post-deploy

1. **make.powerautomate.com → Data → Custom connectors** for each.
2. **Test** → **+ New connection** → sign in with a service account that has the consented Graph/Azure permissions.
3. Validate: run `ListApplications` (Graph) and `ListSubscriptions` (ARM).
4. Save the printed connector ids for future updates (`-GraphConnectorId` / `-ArmConnectorId`).
5. Wire both into the CLM discovery Cloud Flow that upserts `clm_credential` and emits `clm_renewalevent`.

## Secret rotation

`Deploy-CLMConnector.ps1` provisions a 6-month client secret on the Discovery app and embeds it in the connector. To rotate, generate a new secret and re-deploy with `-ClientSecret <new>` plus the existing `-GraphConnectorId` / `-ArmConnectorId`.
