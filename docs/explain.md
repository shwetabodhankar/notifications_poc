# Notification POC — Customer Explanation

## The One-Sentence Version

> "When a work item changes in Azure DevOps, the system automatically figures out who needs to know and sends them a Teams notification — no manual triage required."

---

## The Analogy

Think of it like a **postal sorting office**:

- ADO sends a **letter** (the work item event)
- The **sorting office** reads the label (product, priority, security flag) and looks up the routing table
- It puts the letter in the right **pigeonhole** (Teams channel)
- A **delivery person** takes it to the right door

---

## The 4 Logic Apps — Simple Roles

| App | Role | Analogy |
|---|---|---|
| **Orchestrator** (`la-notif-orchestrator-dev`) | Receives the ADO webhook, validates it, loads routing rules, decides where it goes | The sorting office manager |
| **Dispatcher** (`la-notif-dispatcher-dev`) | Takes the routing decision and fans it out — calls Teams, triggers email escalation if needed | The sorting machine |
| **Teams Notifier** (`la-notif-teams-dev`) | Formats and posts the Adaptive Card to the Teams channel | The delivery person |
| **Email Notifier** (`la-notif-email-dev`) | Sends escalation emails for P1/security items | The registered mail courier |

---

## The Routing Rules — Simple Explanation

> "There's a configuration file that defines four ordered routing rules. The first matching rule determines the destination, and the last rule is a catch-all so nothing gets lost."

**Example:**

| Precedence | Condition | → Teams Channel |
|---|---|---|
| 1 | `Custom.IMSCybersecurity = true` | Cybersecurity Notifications |
| 2 | Priority = P1 | Operations Critical |
| 3 | `Custom.IMSProductLine = DevOps` | Azure DevOps - Project Migration |
| 4 | Anything else | General Support |

Live rules are stored in the SharePoint `RoutingRulesLatest` list and can be updated without redeploying any code. `config/routing-rules.json` remains a source/reference copy.

---

## Why 4 Apps Instead of 1?

> "Each app has a single responsibility so they can be updated, monitored, and scaled independently."

- If Teams is down, the Dispatcher can retry just the Teams step without re-running the routing logic
- If you want to add Slack notifications later, you add a 5th app — nothing else changes
- Each app has its own run history in Azure Portal for easy debugging

---

## End-to-End Flow

```
Azure DevOps
    │
    │  Work item created / updated
    │  (Service Hook → HTTP POST)
    ▼
Orchestrator
    │  1. Validates webhook secret
    │  2. Loads enabled rows from RoutingRulesLatest
    │  3. Matches work item against rules
    │  4. Builds routing decision
    ▼
Dispatcher
    │  5. Calls Teams Notifier (always)
    │  6. Calls Email Notifier (P1 / CyberSecurity only)
    ▼
Teams Notifier                    Email Notifier
    │  7. Formats Adaptive Card       8. Sends escalation email
    │  8. POSTs to webhook URL           to security / ops team
    ▼
Teams Channel
    (Adaptive Card with work item details + link to ADO)
```

---

## The Business Value

1. **No manual triage** — the right team is notified instantly, not after someone reads a shared inbox
2. **Configurable without code** — changing routing rules is editing a JSON file, not deploying new software
3. **Full audit trail** — every Logic App run is logged in Azure with the exact decision path taken
4. **Extensible** — add new channels, products, or notification channels (Slack, PagerDuty) without changing existing apps

---

---

# 10-Minute Talking Pitch

> *Use this as a guide for a live demo or stakeholder walkthrough. Each section is roughly 1–2 minutes.*

---

## 1. Opening — The Problem (1 min)

> "Let me start with the problem we're solving."

Today, when a critical work item is raised in Azure DevOps — a P1 security bug, a hotfix request, a cyber vulnerability — the notification journey is manual. Someone raises the ticket, someone else emails the right team, someone forwards it to security, someone pings the ops channel. By the time the right people know, 30 minutes have passed.

And the bigger the product portfolio, the worse it gets. Ampla has one routing path. InTouch has another. Historian is different again. That tribal knowledge lives in someone's head, not in a system.

This POC answers the question: **can we make that routing automatic, configurable, and auditable — without writing custom application code?**

---

## 2. The Solution in One Sentence (30 sec)

> "When a work item changes in Azure DevOps, this system automatically works out who needs to know and sends them a Teams message and email — the right people, for the right product, at the right priority — in under 5 seconds."

No code deployments to change a routing rule. No manual triage. No missed notifications.

---

## 3. The Architecture — 4 Logic Apps (2 min)

> "The whole thing is built on Azure Logic Apps — Microsoft's low-code workflow engine. There are four apps, each with a single job."

Walk through the flow diagram:

```
Azure DevOps  →  Orchestrator  →  Dispatcher  →  Teams Notifier  →  Teams Channel
                                              →  Email Notifier  →  Email Inbox
```

- **Orchestrator** — the entry point. ADO sends a webhook when a work item is created or updated. The orchestrator uses the signed callback URL, loads routing rules from SharePoint, and determines which rules apply.

- **Dispatcher** — receives the routing decision and fans it out. It calls the Teams notifier for every matched rule, and the email notifier when the rule calls for it.

- **Teams Notifier** — formats a clean HTML message and posts it to the specified Teams channel using the Microsoft Teams API.

- **Email Notifier** — sends a formatted HTML email through Microsoft Graph using the Logic App's managed identity.

> "Why four apps instead of one? Because each one can be updated, monitored, and retried independently. If Teams is having a bad day, you don't lose the email. If you want to add Slack next month, you add a fifth app — nothing else changes."

---

## 4. The Routing Rules — The Heart of the System (2 min)

> "This is the part that makes it genuinely useful for AVEVA."

Open the SharePoint `RoutingRulesLatest` list or show the table.

There are four rules today. Each rule says:

> *"If this is the first rule whose conditions match the work item, send it to this Teams channel and email group."*

Show a few examples:

| Rule | Fires when | Destination |
|---|---|---|
| rule-001 | Cybersecurity = true | Cybersecurity Notifications + CISO team |
| rule-002 | Priority = P1 | Operations Critical |
| rule-003 | IMS Product Line = DevOps | Azure DevOps - Project Migration |
| rule-999 | Anything else | General Support catch-all |

> "Rules are evaluated in configuration order and the first match wins. A P1 cybersecurity item goes only to the cybersecurity destination; a non-security P1 goes to Operations Critical."

> "The critical insight: **none of this is code**. Changing a routing rule means editing a JSON file and uploading it. You can add a new product, a new priority tier, a new channel — without touching any Logic App."

---

## 5. Live Demo Moment (2 min)

> "Let me show it working end-to-end."

Fire a test webhook payload and show:

1. **ADO raises the event** → orchestrator receives it, returns 202 Accepted in under 1 second (doesn't block ADO)
2. **Azure Portal → Orchestrator run** → show Filter_Matching_Rules output — which rules matched and why
3. **Teams channel** → notification appears with work item title, priority, product, state, assigned-to, and a direct link to open in ADO
4. **Email inbox** → HTML email arrives at `sbodhankar@MngEnvMCAP628198.onmicrosoft.com`

> "From webhook to Teams notification — under 5 seconds. And every step is logged and inspectable in Azure."

---

## 6. Security & Operational Considerations (1 min)

> "A few things worth calling out for enterprise readiness."

- **Webhook secret validation** — every incoming request from ADO is validated against a shared secret. Unsigned requests are rejected with 401.
- **SharePoint permissions** — the routing list is available only to the connector account and authorized configuration owners.
- **Managed Identity** — Logic Apps authenticate to storage using Azure Managed Identity, not connection strings or keys. No secrets in config.
- **Async response** — the orchestrator returns 202 immediately and processes asynchronously, so ADO never times out waiting for a response.
- **Full audit trail** — every run, every decision, every matched rule is logged in Azure Monitor with a correlation ID that links the ADO event to the Teams message.

---

## 7. What's Not Here Yet — Honest Gaps (1 min)

> "This is a POC, so I want to be transparent about what's a proof-of-concept assumption versus what's production-ready."

- **Product-line field dependency** — targeted routing uses `Custom.IMSProductLine` in ADO. If it is blank or misspelled, the item falls to the catch-all rule unless a higher-precedence cybersecurity or P1 rule matches.
- **Teams channel per rule** — the DevOps rule uses the provided Azure DevOps - Project Migration channel. Confirm the production channel IDs for the cybersecurity, critical, and general rules before production use.
- **Email authorization** — an Entra administrator must grant the Email Logic App managed identity the Microsoft Graph `Mail.Send` application role and restrict it to the notification mailbox.
- **No deduplication** — if the same work item is updated 10 times in quick succession, you'll get 10 notifications. Rate limiting or deduplication logic would be a production addition.

---

## 8. Close — The Ask (30 sec)

> "So what does this prove?"

It proves that **AVEVA can have intelligent, product-aware, priority-aware notification routing in Azure DevOps — running entirely on Azure PaaS services, with no custom application to maintain, configurable by anyone who can edit a JSON file, and extensible to any channel.**

The ask for the next step is: validate the routing model against AVEVA's real product taxonomy and work item structure, confirm the configured IMS fields, and define the remaining production Teams channel IDs. The infrastructure is ready — it's a data exercise from here.

---

*Total estimated speaking time: ~10 minutes including demo transitions.*
