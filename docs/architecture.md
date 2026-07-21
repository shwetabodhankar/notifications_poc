# Architecture — Azure Logic Apps Enterprise Notification Routing

## 1. High-Level System Architecture

```mermaid
flowchart TB
    subgraph Sources["Event Sources"]
        ADO["Azure DevOps\nWebhook\n(workitem.created / updated)"]
        PA["Power Automate\nFlow (optional)"]
        SF["Salesforce\nService Cloud (future)"]
    end

    subgraph OrchestratorGroup["Logic App — Orchestrator"]
        TRIGGER["HTTP Trigger\nPOST /api/workitem-event"]
        EXTRACT["Normalise\nWork Item Fields"]
        CORRTRACK["Correlation ID\nTracking"]
    end

    subgraph RuleEngineGroup["Azure Function — Rule Engine"]
        LOAAD["Load Rules\nfrom Blob Storage"]
        EVAL["Evaluate Rules\n(JavaScript)"]
        SCENARIOS["Determine\nScenarios A / B / C"]
    end

    subgraph ConfigGroup["Configuration Store (Blob Storage)"]
        BLOB["routing-rules.json\n(zero-redeploy updates)"]
        ALT1["SharePoint List\n(alternative)"]
        ALT2["Dataverse Table\n(alternative)"]
    end

    subgraph DispatcherGroup["Logic App — Dispatcher"]
        PARSE_D["Parse Routing\nDecisions"]
        FANOUT["Fan-out\nForeach Rule Match"]
    end

    subgraph NotifierGroup["Notification Logic Apps"]
        TEAMS_LA["Teams Notifier LA\nAdaptive Card"]
        EMAIL_LA["Email Notifier LA\nHTML Email via SendGrid"]
        SMS_LA["SMS Notifier LA\n(future — Twilio)"]
        SNOW_LA["ServiceNow Notifier\n(future)"]
    end

    subgraph ChannelGroup["Notification Channels"]
        MS_TEAMS["Microsoft Teams\nChannel Incoming Webhooks"]
        EMAIL_DL["Email Distribution\nLists"]
        SMS_CH["SMS / Voice\n(future)"]
        SNOW_CH["ServiceNow\nIncidents (future)"]
    end

    subgraph InfraGroup["Supporting Infrastructure"]
        KV["Azure Key Vault\nSecrets + API Keys"]
        APPI["Application Insights\nDistributed Tracing"]
        LAW["Log Analytics\nWorkspace"]
        ALERTS["Azure Monitor\nAlerts + Dashboards"]
    end

    subgraph AIGroup["Future — AI-Enhanced Administration"]
        COPILOT_STUDIO["Copilot Studio Agent\nor Azure AI Foundry"]
        CATALOG_READ["Product Catalog\nReader (Dataverse)"]
        PATTERN_ANALYSIS["Pattern Analysis\n(Log Analytics)"]
        RULE_SUGGEST["Rule Recommendation\nEngine"]
        ADMIN_APPROVE["Admin Approval\nInterface"]
    end

    ADO -->|"POST + x-webhook-secret"| TRIGGER
    PA -->|"HTTP POST"| TRIGGER
    SF -.->|"future"| TRIGGER

    TRIGGER --> EXTRACT
    EXTRACT --> CORRTRACK
    CORRTRACK -->|"normalised work item"| LOAAD

    BLOB --> LOAAD
    LOAAD --> EVAL
    EVAL --> SCENARIOS
    SCENARIOS -->|"routing decisions JSON"| PARSE_D

    PARSE_D --> FANOUT
    FANOUT -->|"Teams payload"| TEAMS_LA
    FANOUT -->|"Email payload"| EMAIL_LA
    FANOUT -.->|"future"| SMS_LA
    FANOUT -.->|"future"| SNOW_LA

    TEAMS_LA -->|"Adaptive Card\nvia incoming webhook"| MS_TEAMS
    EMAIL_LA -->|"HTML email\nvia SendGrid API"| EMAIL_DL
    SMS_LA -.-> SMS_CH
    SNOW_LA -.-> SNOW_CH

    KV -.->|"secrets"| TRIGGER
    KV -.->|"secrets"| LOAAD
    KV -.->|"SendGrid API key"| EMAIL_LA
    KV -.->|"Teams webhook URLs"| BLOB

    TRIGGER --> APPI
    LOAAD --> APPI
    PARSE_D --> APPI
    TEAMS_LA --> APPI
    EMAIL_LA --> APPI
    APPI --> LAW
    LAW --> ALERTS

    COPILOT_STUDIO --> CATALOG_READ
    COPILOT_STUDIO --> PATTERN_ANALYSIS
    PATTERN_ANALYSIS --> RULE_SUGGEST
    RULE_SUGGEST --> ADMIN_APPROVE
    ADMIN_APPROVE -.->|"approved rules written back"| BLOB
```

---

## 2. Event Processing Sequence

```mermaid
sequenceDiagram
    autonumber
    participant ADO as Azure DevOps
    participant ORCH as Orchestrator LA
    participant KV as Key Vault
    participant FUNC as Rule Engine (AF)
    participant BLOB as Blob Storage
    participant DISP as Dispatcher LA
    participant TEAMS as Teams Notifier LA
    participant EMAIL as Email Notifier LA
    participant APPI as App Insights

    ADO->>+ORCH: POST /api/workitem-event<br/>(x-webhook-secret header)
    ORCH->>ORCH: Generate correlationId<br/>Validate event type
    ORCH->>KV: Get webhook shared secret (cached)
    KV-->>ORCH: Secret value
    ORCH->>ORCH: Normalise work item fields<br/>(product, priority, flags, etc.)
    ORCH->>APPI: Track event received (correlationId)

    ORCH->>+FUNC: POST /api/evaluate-rules<br/>{workItem fields}
    FUNC->>+BLOB: Download routing-rules.json
    BLOB-->>-FUNC: Rules JSON (cached 5 min)
    FUNC->>FUNC: Filter enabled rules<br/>Sort by priority<br/>Evaluate conditions
    FUNC->>FUNC: Determine scenarios (A/B/C)
    FUNC->>APPI: Track rule evaluation
    FUNC-->>-ORCH: {routingDecisions[], scenarios[]}

    ORCH->>+DISP: POST /api/dispatch<br/>{workItem, routingDecisions}
    ORCH-->>-ADO: 200 Acknowledged<br/>{correlationId, status}

    loop For each routing decision
        DISP->>+TEAMS: POST /api/notify-teams<br/>{channelWebhookUrl, workItem}
        TEAMS->>TEAMS: Build Adaptive Card
        TEAMS->>TEAMS: POST to Teams incoming webhook
        TEAMS-->>-DISP: {status: sent}

        DISP->>+EMAIL: POST /api/notify-email<br/>{emailTo, workItem, scenario}
        EMAIL->>KV: Get SendGrid API key (cached)
        EMAIL->>EMAIL: Build HTML email
        EMAIL->>EMAIL: POST to SendGrid API
        EMAIL-->>-DISP: {status: sent}
    end

    DISP-->>APPI: Track dispatch complete
    DISP->>APPI: Track notifications sent
```

---

## 3. Rule Evaluation Logic

```mermaid
flowchart TD
    START([Work Item Fields Received]) --> LOAD
    LOAD[Load routing-rules.json\nfrom Blob Storage] --> FILTER
    FILTER[Filter: enabled = true] --> SORT
    SORT[Sort by rule.priority ASC\nlower = higher precedence] --> FOREACH

    FOREACH{For Each Rule} --> MATCH
    MATCH{Evaluate Conditions}

    MATCH -->|"product matches\n(or Any)"| C2
    C2{productFamily\nmatches?} -->|yes| C3
    C3{areaPath\ncontains?} -->|yes| C4
    C4{priority\nmatches?} -->|yes| C5
    C5{workItemType\nmatches?} -->|yes| C6
    C6{isCyberSecurity\nmatches?} -->|yes| C7
    C7{isHotfix\nmatches?} -->|yes| MATCHED

    MATCH -->|no match| NEXT
    C2 -->|no| NEXT
    C3 -->|no| NEXT
    C4 -->|no| NEXT
    C5 -->|no| NEXT
    C6 -->|no| NEXT
    C7 -->|no| NEXT

    MATCHED[Add to matchedRules] --> NEXT
    NEXT{More rules?} -->|yes| FOREACH
    NEXT -->|no| SCENARIOS

    SCENARIOS[Determine Scenarios\nA always\nB if priority = P1\nC if isCyberSecurity = true] --> RETURN

    RETURN([Return routingDecisions\nfrom all matched rules])
```

---

## 4. Routing Rule Data Model

```mermaid
erDiagram
    RULE {
        string id PK
        int priority
        string name
        bool enabled
        datetime effectiveFrom
        datetime effectiveTo
        string createdBy
        string modifiedBy
    }
    CONDITIONS {
        string ruleId FK
        string product
        string productFamily
        string areaPath
        string priority
        string workItemType
        bool isCyberSecurity
        bool isHotfix
    }
    ROUTING {
        string ruleId FK
        string teamsChannelName
        string teamsChannelWebhookUrl
        string emailGroup
        string escalationGroup
        string securityLiaison
        string[] scenarios
    }
    RULE ||--|| CONDITIONS : "has"
    RULE ||--|| ROUTING : "produces"
```

---

## 5. Bicep Deployment Topology

```mermaid
flowchart TD
    MAIN["main.bicep\n(deployment entry point)"]

    MAIN --> STORAGE["modules/storage.bicep\nStorage Account\nrouting-rules container\nMinTLS 1.2, no public blob"]
    MAIN --> KV["modules/keyvault.bicep\nKey Vault (standard)\nRBAC enabled\nSoft-delete + purge protection"]
    MAIN --> APPI["modules/app-insights.bicep\nApplication Insights\nLog Analytics Workspace\n90-day retention"]
    MAIN --> FUNCS["modules/functions.bicep\nApp Service Plan (Y1 Consumption)\nFunction App (Node 18)\nSystem-assigned MI"]
    MAIN --> LA["modules/logic-apps.bicep\n4x Logic Apps (Consumption)\nSystem-assigned MI each\nDiagnostic settings → LAW"]

    FUNCS -->|"RBAC: Storage Blob Data Reader"| STORAGE
    FUNCS -->|"RBAC: Key Vault Secrets User"| KV
    LA -->|"RBAC: Key Vault Secrets User"| KV
    LA -->|"Diagnostic logs"| APPI
    FUNCS -->|"APPINSIGHTS_INSTRUMENTATIONKEY"| APPI
```

---

## 6. Error Handling Strategy

```mermaid
flowchart TD
    EVENT[Incoming Webhook Event] --> SCOPE_MAIN

    subgraph SCOPE_MAIN["Scope: Main Processing (Orchestrator)"]
        VALIDATE[Validate event type] --> EXTRACT_F
        EXTRACT_F[Extract fields] --> CALL_RE
        CALL_RE[Call Rule Engine\nRetry: exponential x3\nMax interval: 60s] --> CALL_DISP
        CALL_DISP[Call Dispatcher\nRetry: exponential x3\nMax interval: 120s]
    end

    SCOPE_MAIN -->|"Failed / TimedOut"| SCOPE_ERR

    subgraph SCOPE_ERR["Scope: Error Handler"]
        LOG_ERR[Compose error details\ncorrelationId + action results] --> ALERT_APPI
        ALERT_APPI[Track custom event\nin App Insights] --> NOTIFY_OPS
        NOTIFY_OPS[Notify Ops channel\n(critical failures only)]
    end

    SCOPE_MAIN -->|"Succeeded / Skipped"| ACK_200
    SCOPE_ERR -->|"Succeeded / Skipped"| ACK_200

    ACK_200["Response 200 OK\n(always — prevent ADO retry storms)"]
```

**Key decisions:**
- Always return `HTTP 200` to the Azure DevOps webhook to prevent ADO from retrying and flooding the pipeline.
- Use `Scope` actions to isolate failures without breaking the acknowledgement response.
- Use exponential retry on all outbound HTTP calls (3 attempts, 5 s → 60 s intervals).
- Dead-letter failed events to a storage queue for manual replay.

---

## 7. Future AI-Enhanced Administration Model

```mermaid
flowchart TB
    subgraph AI_AGENT["AI Agent (Copilot Studio / AI Foundry)"]
        AGENT_TRIGGER["Trigger: Scheduled Daily\nor Admin Chat Message"]
        READ_CATALOG["Read Product Catalog\n(Dataverse / SharePoint)"]
        READ_LOGS["Analyse Routing Patterns\n(Log Analytics KQL)"]
        READ_RULES["Read Current Rules\n(Blob Storage)"]
        GENERATE["Generate Rule Recommendations\n(GPT-4o with function calling)"]
        DIFF["Compute Rule Diff\n(new, modified, obsolete)"]
        PRESENT["Present to Admin\n(Adaptive Card in Teams)"]
        APPROVE{Admin\nApproves?}
        WRITE_BACK["Write Approved Rules\nto Blob Storage\n(via Logic App)"]
        AUDIT["Write Audit Entry\n(Log Analytics)"]
    end

    AGENT_TRIGGER --> READ_CATALOG
    READ_CATALOG --> READ_LOGS
    READ_LOGS --> READ_RULES
    READ_RULES --> GENERATE
    GENERATE --> DIFF
    DIFF --> PRESENT
    PRESENT --> APPROVE
    APPROVE -->|"Yes"| WRITE_BACK
    APPROVE -->|"No"| AUDIT
    WRITE_BACK --> AUDIT
```

### AI Agent Tools (Function Calling)

| Tool Name | Description |
|-----------|-------------|
| `get_product_catalog` | Retrieves all products and families from Dataverse |
| `get_routing_rules` | Reads current routing-rules.json from Blob |
| `get_notification_statistics` | KQL query over Log Analytics for routing hit rates |
| `get_unmatched_events` | Events that matched only the catch-all rule |
| `propose_rule_changes` | Returns structured JSON diff of proposed changes |
| `apply_rule_changes` | Writes approved rules back after admin confirmation |

---

## 8. Monitoring Dashboard KQL Queries

### Events Processed Per Hour
```kusto
customEvents
| where name == "WorkItemEventReceived"
| summarize count() by bin(timestamp, 1h)
| render timechart
```

### Rules Matched Distribution
```kusto
customEvents
| where name == "RuleEvaluationComplete"
| extend matchCount = toint(customDimensions["matchedRuleCount"])
| summarize avg(matchCount), max(matchCount), count() by bin(timestamp, 1h)
```

### Notification Delivery Failures
```kusto
customEvents
| where name == "NotificationFailed"
| project timestamp, correlationId = tostring(customDimensions["correlationId"]),
    channel = tostring(customDimensions["channel"]),
    reason = tostring(customDimensions["reason"])
| order by timestamp desc
```

### Processing Latency (End-to-End)
```kusto
customEvents
| where name in ("WorkItemEventReceived", "DispatchComplete")
| extend correlationId = tostring(customDimensions["correlationId"])
| summarize startTime = min(timestamp), endTime = max(timestamp) by correlationId
| extend latencyMs = datetime_diff('millisecond', endTime, startTime)
| summarize avg(latencyMs), percentile(latencyMs, 95), percentile(latencyMs, 99)
```
