# Azure Logic Apps Enterprise Notification Routing POC

## Overview

This proof of concept receives Azure DevOps work-item events, loads routing rules from a SharePoint document library, evaluates the rules, and sends notifications through Microsoft Teams and email.

```text
Azure DevOps Service Hook
        |
        v
Orchestrator Logic App --reads--> SharePoint routing-rules.json
        |
        v
Dispatcher Logic App
        |
        +----> Teams Connector Logic App ----> Teams channel
        |
        +----> Email Notifier Logic App -----> Email recipients
```

The Azure DevOps Service Hook calls a signed Logic App callback URL. The URL signature authenticates the request; no custom `x-webhook-secret` header is required.

## Components

| Component | Purpose |
|---|---|
| Orchestrator Logic App | Receives events, normalizes work-item fields, reads SharePoint rules, and selects matching routes |
| Dispatcher Logic App | Fans matching routes out to notification channels |
| Teams Connector Logic App | Posts messages through an authenticated Microsoft Teams API connection |
| Email Notifier Logic App | Sends email through SendGrid |
| SharePoint document library | Hosts the live `routing-rules.json` configuration with document version history |
| Application Insights and Log Analytics | Store workflow diagnostics and telemetry |

## Prerequisites

- Azure CLI 2.55 or later with Bicep installed
- Node.js 18 or later
- Contributor access to the target Azure subscription or resource group
- A SharePoint site and document library
- A Microsoft 365 account that can read the SharePoint document
- A Teams-licensed Microsoft 365 account that can post to the destination Team and channel
- Permission to create Azure DevOps Service Hook subscriptions

## 1. Prepare SharePoint

1. Open the target SharePoint site.
2. Open its **Documents** library.
3. Upload [config/routing-rules.json](config/routing-rules.json).
4. Ensure the SharePoint connector account has read permission on the site and file.
5. Keep SharePoint version history enabled for auditing and rollback.

The current development configuration uses:

```text
Site: https://mngenvmcap628198.sharepoint.com/sites/demosite
File: /Shared Documents/routing-rules.json
```

The path is site-relative and must include the document library name. Updating the SharePoint file changes routing without redeploying the Logic Apps.

## 2. Prepare Teams

1. Create or select the destination Team and channel.
2. Add the Teams connector account to the Team. Add it explicitly to private channels.
3. In Teams, open the channel menu and select **Get link to channel**.
4. Extract `groupId` from the query string. This is `teamsTeamId`.
5. Decode the channel segment after `/channel/`. This is `teamsChannelId` and normally has the form `19:...@thread.tacv2`.
6. Add those values to each rule in `routing-rules.json`:

```json
"routing": {
  "teamsChannelName": "Devops Notification Channel",
  "teamsTeamId": "00000000-0000-0000-0000-000000000000",
  "teamsChannelId": "19:example@thread.tacv2"
}
```

The connector path does not require Power Automate, a Teams Workflow, or an incoming webhook URL.

## 3. Deploy Azure Resources

Sign in and select the intended subscription:

```powershell
az login
az account set --subscription "<SUBSCRIPTION_ID>"
```

Deploy the development environment:

```powershell
.\scripts\deploy.ps1 `
  -Environment dev `
  -ResourceGroup rg-notifications-dev `
  -Location westus2 `
  -OwnerTech "technical.owner@aveva.com" `
  -OwnerBusiness "business.owner@aveva.com" `
  -Team "RESEARCH TEAM" `
  -SharePointSiteUrl "https://mngenvmcap628198.sharepoint.com/sites/demosite" `
  -SharePointRulesFilePath "/Shared Documents/routing-rules.json" `
  -SharePointServiceAccountEmail "service.account@contoso.com"
```

`OwnerTech`, `OwnerBusiness`, and `Team` are required by AVEVA Azure Policy. The SharePoint arguments are optional and default to the development values shown above.

The deployment is incremental. Re-running it updates existing Logic Apps without deleting SharePoint files or Azure DevOps Service Hooks.

## 4. Authorize API Connections

Bicep creates the API connection resources, but an interactive sign-in is required after the first deployment.

### SharePoint connection

1. In Azure Portal, open resource group `rg-notifications-dev`.
2. Open `conn-sharepoint-la-notif-orchestrator-dev`.
3. Select **Edit API connection**.
4. Select **Authorize** and sign in with the SharePoint connector account.
5. Select **Save**.

### Teams connection

1. Open `conn-teams-la-notif-teams-dev`.
2. Select **Edit API connection**.
3. Select **Authorize** and sign in with the Teams connector account.
4. Select **Save**.

Both resources must show `Connected`. Reauthorize a connection if its account, password, conditional-access policy, or consent changes.

## 5. Get the Orchestrator Callback URL

The complete callback URL is a credential. Do not commit it, publish it, or remove its `sig`, `sp`, or `sv` query parameters.

### Azure Portal

1. Open `la-notif-orchestrator-dev` in Azure Portal.
2. Open **Logic app designer**.
3. Select `Receive_WorkItem_Webhook`.
4. Copy the **HTTP POST URL**.

### Azure CLI

```powershell
$subscriptionId = az account show --query id --output tsv
$resourceGroup = "rg-notifications-dev"
$logicApp = "la-notif-orchestrator-dev"
$trigger = "Receive_WorkItem_Webhook"

$callbackUrl = az rest `
  --method post `
  --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/$logicApp/triggers/$trigger/listCallbackUrl?api-version=2019-05-01" `
  --query value `
  --output tsv
```

Use `$callbackUrl` directly. Do not print it in shared logs.

## 6. Configure Azure DevOps Service Hooks

Create two subscriptions because Azure DevOps treats creation and update as separate event types.

1. Open the Azure DevOps project.
2. Go to **Project settings > General > Service hooks**.
3. Select **Create subscription**.
4. Select **Web Hooks**, then select **Next**.
5. For the first subscription, choose **Work item created**.
6. Add optional area-path, work-item-type, or tag filters. Leave them empty to process all work items.
7. Select **Next**.
8. Enter the complete signed Logic App callback URL in **URL**.
9. Set **Resource details to send** to **All** so custom fields are included.
10. Select **Test** and verify that Azure DevOps receives a successful response.
11. Select **Finish**.
12. Repeat the process with **Work item updated**.

Do not configure Basic Authentication or an additional shared-secret header. Access is controlled by the signed callback URL.

## 7. Validate End to End

Create or update an Azure DevOps work item whose fields match a rule. For example:

```text
Work item type: Bug
Priority: 1
Custom.Product: Ampla
Custom.ProductFamily: SCADA
Custom.IsCyberSecurity: true
Custom.IsHotfix: false
```

Then verify the run chain in Azure Portal:

1. `la-notif-orchestrator-dev`
   Confirm `Load_Routing_Rules`, `Filter_Matching_Rules`, and `Call_Dispatcher` succeeded.
2. `la-notif-dispatcher-dev`
   Confirm at least one routing decision was processed.
3. `la-notif-teams-dev-connector`
   Confirm `Post_To_Teams_Channel` succeeded.
4. Open the configured Teams channel and confirm the notification arrived.

The Orchestrator returns HTTP `202 Accepted` before all downstream processing finishes. Use Logic App run history to verify final delivery.

## Routing Rules

Rules are evaluated in ascending numeric `priority`; lower values run first. More than one rule can match, producing multiple notifications.

| Condition | Azure DevOps source | Wildcard |
|---|---|---|
| `product` | `Custom.Product` | `"Any"` or `null` |
| `productFamily` | `Custom.ProductFamily` | `null` |
| `areaPath` | `System.AreaPath` substring | `null` |
| `priority` | `Microsoft.VSTS.Common.Priority` | `"Any"` |
| `workItemType` | `System.WorkItemType` | `null` |
| `isCyberSecurity` | `Custom.IsCyberSecurity` | `null` |
| `isHotfix` | `Custom.IsHotfix` | `null` |

Before uploading a changed file to SharePoint, validate it locally:

```powershell
Set-Location .\functions

node -e "const Ajv=require('ajv');const addFormats=require('ajv-formats');const fs=require('fs');const schema=JSON.parse(fs.readFileSync('../config/routing-schema.json','utf8'));const data=JSON.parse(fs.readFileSync('../config/routing-rules.json','utf8'));const ajv=new Ajv({allErrors:true});addFormats(ajv);const ok=ajv.validate(schema,data);console.log(ok?'Schema validation passed':ajv.errors);process.exit(ok?0:1)"
```

## Operations and Security

- Treat the complete callback URL as a secret. Regenerate its signature if it is exposed.
- Grant SharePoint edit access only to routing administrators.
- Use separate SharePoint files and callback URLs for development, staging, and production.
- Keep the Teams and SharePoint connector accounts licensed and limited to the required sites and channels.
- Review Logic App run history and Application Insights when notifications do not arrive.
- A SharePoint change does not require an Azure deployment. A workflow or Bicep change does.

## Key Files

| Path | Purpose |
|---|---|
| [config/routing-rules.json](config/routing-rules.json) | Source copy of the SharePoint routing configuration |
| [config/routing-schema.json](config/routing-schema.json) | Validation schema for routing rules |
| [logic-apps/orchestrator.json](logic-apps/orchestrator.json) | Signed callback, SharePoint loading, and rule matching |
| [logic-apps/dispatcher.json](logic-apps/dispatcher.json) | Notification fan-out |
| [logic-apps/teams-notifier-connector.json](logic-apps/teams-notifier-connector.json) | Teams managed-connector delivery |
| [bicep/main.bicep](bicep/main.bicep) | Root infrastructure deployment |
| [bicep/modules/logic-apps.bicep](bicep/modules/logic-apps.bicep) | Logic Apps and API connections |
| [scripts/deploy.ps1](scripts/deploy.ps1) | Deployment entry point |
