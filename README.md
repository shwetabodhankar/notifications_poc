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
| Email Notifier Logic App | Sends email through Microsoft Graph using managed identity |
| SharePoint document library | Hosts the live `routing-rules.json` configuration with document version history |
| Application Insights and Log Analytics | Store workflow diagnostics and telemetry |

## Prerequisites

- Azure CLI 2.55 or later with Bicep installed
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
3. In the Teams desktop or web client, select the three-dot menu next to the channel.
4. Select **Get link to channel**, then select **Copy**.
5. Identify the encoded value between `/channel/` and the channel display name. URL-decode this value to obtain `teamsChannelId`.
6. Read the `groupId` query-string value to obtain `teamsTeamId`.
7. Read the `tenantId` query-string value when you need to confirm which Microsoft Entra tenant owns the Team.

For example, this channel link:

```text
https://teams.cloud.microsoft/l/channel/19%3ANQb2njN0ABU9cqxTnQXgcqrjf9XojzGs2NC9D20cIYM1%40thread.tacv2/Devops%20Notification%20Channel?groupId=a5b3fdd9-4ffb-49a4-916c-15f5aea86fef&tenantId=c508696d-bdfc-487a-b57b-138782c41da2
```

contains:

```text
teamsChannelId = 19:NQb2njN0ABU9cqxTnQXgcqrjf9XojzGs2NC9D20cIYM1@thread.tacv2
teamsTeamId    = a5b3fdd9-4ffb-49a4-916c-15f5aea86fef
tenantId       = c508696d-bdfc-487a-b57b-138782c41da2
```

You can extract the values in PowerShell:

```powershell
$channelLink = "<PASTE_TEAMS_CHANNEL_LINK>"
$channelUri = [uri]$channelLink
$pathParts = $channelUri.AbsolutePath.Trim('/').Split('/')
$query = [System.Web.HttpUtility]::ParseQueryString($channelUri.Query)

$teamsChannelId = [uri]::UnescapeDataString($pathParts[2])
$teamsTeamId = $query['groupId']
$tenantId = $query['tenantId']

[pscustomobject]@{
  TeamsChannelId = $teamsChannelId
  TeamsTeamId = $teamsTeamId
  TenantId = $tenantId
}
```

8. Add the Team and channel IDs to each applicable rule in `routing-rules.json`:

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

### Microsoft Graph email permission

The Email Logic App uses a system-assigned managed identity and does not require an API connection or secret. After deployment, an Entra administrator must grant that identity the Microsoft Graph `Mail.Send` application role:

```powershell
.\scripts\grant-graph-mail-permission.ps1 `
  -SubscriptionId "<SUBSCRIPTION_ID>" `
  -ResourceGroup "rg-notifications-dev"
```

`Mail.Send` application permission is tenant-wide by default. Before production use, an Exchange administrator must use Exchange Online application RBAC to restrict the Email Logic App identity to the mailbox configured by `notificationFromEmail`.

## 5. Get the Orchestrator Callback URL

Generate the callback URL after deploying the Logic App. The complete URL contains a SAS signature and is a credential. Do not commit it, publish it, or remove its `sig`, `sp`, or `sv` query parameters.

### Azure Portal

1. In Azure Portal, open resource group `rg-notifications-dev`.
2. Open the Consumption Logic App `la-notif-orchestrator-dev`.
3. Open **Logic app designer**.
4. Expand or select the request trigger named `Receive_WorkItem_Webhook`.
5. Copy the **HTTP POST URL** shown by the trigger.
6. Confirm the copied URL includes all of these query-string parameters:
   `api-version`, `sp`, `sv`, and `sig`.
7. Paste the complete URL into the Azure DevOps Web Hook **URL** field. Do not add quotation marks or remove URL-encoded characters.

### Azure CLI

```powershell
# Sign in and select the target subscription first.
az login
az account set --subscription "<SUBSCRIPTION_ID>"

$subscriptionId = az account show --query id --output tsv
$resourceGroup = "rg-notifications-dev"
$logicApp = "la-notif-orchestrator-dev"
$trigger = "Receive_WorkItem_Webhook"

$callbackRequestUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/$logicApp/triggers/$trigger/listCallbackUrl?api-version=2019-05-01"

$callbackUrl = az rest `
  --method post `
  --uri $callbackRequestUri `
  --query value `
  --output tsv

if (-not $callbackUrl -or $callbackUrl -notmatch '[?&]sig=') {
  throw "A valid signed callback URL was not returned."
}

# Put the credential on the clipboard without printing it to shared logs.
$callbackUrl | Set-Clipboard
Write-Host "Signed callback URL copied to the clipboard."
```

Paste the clipboard value directly into each Azure DevOps Web Hook subscription. The same Orchestrator callback can receive both `workitem.created` and `workitem.updated` events.

If Azure returns `ResourceNotFound`, verify the resource group, Logic App name, and trigger name. If it returns `AuthorizationFailed`, confirm the signed-in identity can read the Logic App and invoke `listCallbackUrl`.

If the callback URL is exposed, regenerate the trigger access key in Azure Portal and update both Azure DevOps Service Hook subscriptions with the newly generated URL.

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
Custom.IMSProduct: Development Tools
Custom.IMSProductLine: DevOps
Custom.IMSCybersecurity: true
Custom.IMSHotfix: false
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

You can also submit the checked-in sample event from PowerShell:

```powershell
.\scripts\test-e2e.ps1 -ResourceGroup rg-notifications-dev -Environment dev
```

## Routing Rules

Rules are listed in ascending numeric `priority`; lower values have higher precedence. The first matching rule produces the notification, so keep the catch-all rule last.

| Condition | Azure DevOps source | Wildcard |
|---|---|---|
| `product` | `Custom.IMSProduct` | `"Any"` or `null` |
| `productLine` | `Custom.IMSProductLine` | `null` |
| `areaPath` | `System.AreaPath` substring | `null` |
| `priority` | `Microsoft.VSTS.Common.Priority` | `"Any"` |
| `workItemType` | `System.WorkItemType` | `null` |
| `isCyberSecurity` | `Custom.IMSCybersecurity` | `null` |
| `isHotfix` | `Custom.IMSHotfix` | `null` |

`routing.emailGroup` accepts one address or a comma-separated list of addresses. The Email Logic App trims whitespace and sends one Graph message to all listed recipients.

Before uploading a changed file to SharePoint, validate it locally:

```powershell
.\scripts\validate-rules.ps1
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
| [scripts/validate-rules.ps1](scripts/validate-rules.ps1) | Local routing-schema validation |
