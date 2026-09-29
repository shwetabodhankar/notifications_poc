# Architecture

## Runtime Flow

```mermaid
flowchart LR
    ADO[Azure DevOps Service Hooks] -->|Signed callback URL| ORCH[Orchestrator Logic App]
    ORCH -->|Get enabled items ordered by priority| SP[SharePoint RoutingRulesLatest list]
    ORCH --> DISP[Dispatcher Logic App]
    DISP --> TEAMS[Teams Connector Logic App]
    DISP --> EMAIL[Email Notifier Logic App]
    TEAMS --> CHANNEL[Microsoft Teams channel]
    EMAIL --> RECIPIENTS[Email recipients]
    ORCH -. diagnostics .-> AI[Application Insights and Log Analytics]
    DISP -. diagnostics .-> AI
    TEAMS -. diagnostics .-> AI
    EMAIL -. diagnostics .-> AI
```

## Components

| Component | Responsibility |
|---|---|
| Azure DevOps Service Hooks | Send `workitem.created` and `workitem.updated` events |
| Orchestrator | Normalize work-item fields, load rules from SharePoint, evaluate matches, and call the Dispatcher |
| SharePoint API connection | Authenticate the Orchestrator's read access to the routing list |
| Dispatcher | Fan matching rules out to Teams and email |
| Teams connector | Post to the Team and channel identified by `teamsTeamId` and `teamsChannelId` |
| Email notifier | Send primary and escalation messages through Microsoft Graph using managed identity |
| Application Insights | Collect Logic App runtime diagnostics |

## Authentication

The Azure DevOps endpoint is the signed callback URL generated for `Receive_WorkItem_Webhook`. Its SAS query parameters authenticate invocation, so no custom webhook header is required.

SharePoint and Teams use Azure managed API connections authorized by Microsoft 365 accounts. The SharePoint account requires read access to the routing list. The Teams account requires membership and posting permission in each destination channel.

## Routing Configuration

The live configuration is the SharePoint list `RoutingRulesLatest`. The Orchestrator reads enabled rows for each event in ascending numeric `Priority` order, so changing list rows does not require an Azure deployment.

Each route contains matching conditions and destinations. Rules may overlap, but only the first matching enabled rule is dispatched. Lower numeric priorities are evaluated first. In Yes/No condition columns, `Yes` requires a true work-item value and `No` represents a wildcard.

## Deployment

[bicep/main.bicep](../bicep/main.bicep) deploys:

- Application Insights and Log Analytics
- Orchestrator Logic App
- Dispatcher Logic App
- Teams connector Logic App
- Email notifier Logic App
- SharePoint API connection
- Teams API connection

The deployment does not provision an Azure Function, routing storage account, Key Vault, Power Automate workflow, or Teams incoming webhook.
