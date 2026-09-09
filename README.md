# Azure Logic Apps — Enterprise Notification Routing POC

## Overview

Proof of Concept for an enterprise notification routing system built on **Azure Logic Apps (Consumption)** and **Azure Functions (Node.js)**. Receives Azure DevOps work item webhooks, evaluates configurable routing rules, and dispatches notifications to Microsoft Teams and email distribution groups with full escalation support.

## Architecture at a Glance

```
Azure DevOps Webhook / Power Automate
              │
              ▼
   ┌─────────────────────┐
   │  Orchestrator LA    │  Receives event, extracts fields, tracks correlation
   └────────┬────────────┘
            │
            ▼
   ┌─────────────────────┐   reads   ┌──────────────────────────┐
   │  Rule Engine (AF)   │ ◄──────── │ routing-rules.json       │
   │  Azure Function     │           │ Azure Blob Storage       │
   └────────┬────────────┘           └──────────────────────────┘
            │
            ▼
   ┌─────────────────────┐
   │  Dispatcher LA      │  Fan-out to notification channels
   └──────┬────────┬─────┘
          │        │
          ▼        ▼
   ┌────────┐  ┌────────┐
   │ Teams  │  │ Email  │   (SMS, ServiceNow, Jira — future channels)
   │   LA   │  │   LA   │
   └────────┘  └────────┘
```

## Component Inventory

| Component | Azure Resource Type | Purpose |
|-----------|-------------------|---------|
| Orchestrator | Logic App (Consumption) | HTTP trigger, field normalisation, correlation ID |
| Rule Engine | Azure Function v4 (Node.js 18) | Loads and evaluates routing rules |
| Dispatcher | Logic App (Consumption) | Fan-out to notification Logic Apps |
| Teams Notifier | Logic App (Consumption) | Posts Adaptive Card to Teams incoming webhook |
| Email Notifier | Logic App (Consumption) | Sends HTML email via SendGrid |
| Routing Config | Azure Blob Storage (JSON) | Externalised, zero-redeploy rule changes |
| Secrets | Azure Key Vault | API keys, webhook URLs, shared secrets |
| Observability | Application Insights + Log Analytics | Telemetry, tracing, dashboards, alerts |

## Notification Scenarios

| Scenario | Trigger Condition | Channels |
|----------|------------------|---------|
| A — Standard | Any work item event | Owning product Teams channel + email DL |
| B — Critical | Priority = P1 | Product team + management escalation group |
| C — Cyber Security | IsCyberSecurity = true | Product team + security liaison + central PSIRT |

## Rule Matching Fields

| Field | Source | Wildcard Value |
|-------|--------|---------------|
| `product` | `Custom.Product` | `"Any"` |
| `productFamily` | `Custom.ProductFamily` | `null` |
| `areaPath` | `System.AreaPath` (contains) | `null` |
| `priority` | `Microsoft.VSTS.Common.Priority` | `"Any"` |
| `workItemType` | `System.WorkItemType` | `null` |
| `isCyberSecurity` | `Custom.IsCyberSecurity` | `null` |
| `isHotfix` | `Custom.IsHotfix` | `null` |

## Quick Start

### Prerequisites
- Azure CLI ≥ 2.55 with Bicep extension
- Node.js 18 LTS
- Azure Functions Core Tools v4
- Contributor access on target subscription

### 1 — Deploy Infrastructure

```powershell
cd c:\Projects\aveva\notificationspoc

az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

.\scripts\deploy.ps1 `
  -Environment dev `
  -ResourceGroup rg-notifpoc-dev `
  -Location westus `
  -OwnerTech "technical.owner@aveva.com" `
  -OwnerBusiness "business.owner@aveva.com" `
  -Team "<OFFICIAL_TEAM_NAME>"
```

`OwnerTech`, `OwnerBusiness`, `CreateDate`, and `team` are required by AVEVA Azure Policy. The script validates the two owner addresses, generates `CreateDate` in `yyyy.MM.dd` format, and applies the same tags to the resource group and deployed resources.

### 2 — Upload Routing Rules

```powershell
.\scripts\upload-rules.ps1 -ResourceGroup rg-notifpoc-dev
```

### 3 — Configure Azure DevOps Webhook

1. Open **[AgileProject → Project Settings → Service Hooks → Webhooks](https://dev.azure.com/sbodhankar0209/AgileProject/_settings/serviceHooks)**
2. Create hooks for `workitem.created` and `workitem.updated`
3. Set URL to the Orchestrator trigger URL (output from deploy script)
4. Add HTTP header: `x-webhook-secret: <value from Key Vault secret webhookSharedSecret>`

### 4 — Add Teams Incoming Webhooks

For each product team channel:
1. In Teams, **channel → Connectors → Incoming Webhook**
2. Copy the webhook URL
3. Add to `routing-rules.json` in the `teamsChannelWebhookUrl` field of the matching rule
4. Re-run `upload-rules.ps1`

### 5 — Validate

```powershell
# Send a test event
$orchestratorUrl = az logic workflow show `
  --resource-group rg-notifpoc-dev `
  --name la-notif-orchestrator-dev `
  --query "properties.accessEndpoint" -o tsv

$testPayload = Get-Content .\docs\samples\ado-webhook-sample.json | ConvertFrom-Json
Invoke-RestMethod -Method Post `
  -Uri "$orchestratorUrl/triggers/Receive_WorkItem_Webhook/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2FReceive_WorkItem_Webhook%2Frun&sv=1.0&sig=<SIG>" `
  -ContentType "application/json" `
  -Body ($testPayload | ConvertTo-Json -Depth 10)
```

## File Structure

```
notificationspoc/
├── README.md
├── docs/
│   ├── architecture.md                 # Mermaid diagrams, design rationale
│   └── risks-and-recommendations.md    # Security, ops, extensibility
├── config/
│   ├── routing-rules.json              # Live routing configuration
│   ├── routing-rules.csv               # CSV equivalent for business owners
│   └── routing-schema.json             # JSON Schema for CI validation
├── logic-apps/
│   ├── orchestrator.json               # Workflow definition (Consumption)
│   ├── dispatcher.json
│   ├── teams-notifier.json
│   └── email-notifier.json
├── functions/
│   ├── host.json
│   ├── package.json
│   └── rule-engine/
│       ├── function.json               # HTTP trigger binding
│       └── index.js                    # Rule evaluation engine
├── bicep/
│   ├── main.bicep
│   ├── modules/
│   │   ├── storage.bicep
│   │   ├── keyvault.bicep
│   │   ├── app-insights.bicep
│   │   ├── logic-apps.bicep
│   │   └── functions.bicep
│   └── parameters/
│       ├── main.dev.bicepparam
│       └── main.prod.bicepparam
└── scripts/
    ├── deploy.ps1
    └── upload-rules.ps1
```

## Future AI Extension (Design Only)

A Copilot Studio or Azure AI Foundry agent will:
1. Read the product catalog from Dataverse / SharePoint
2. Analyse historical notification patterns from Log Analytics
3. Recommend new routing rules or modifications
4. Present proposed changes to an administrator for approval
5. Write approved changes back to `routing-rules.json` in Blob Storage

See `docs/architecture.md` — *AI-Enhanced Administration Model* section.
