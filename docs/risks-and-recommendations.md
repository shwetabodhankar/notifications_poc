# Risks and Recommendations

## Security

### R-SEC-01 — Webhook Authentication
**Risk:** The Orchestrator HTTP trigger URL contains a SAS signature in the querystring. If leaked, any caller can inject arbitrary work item events.  
**Likelihood:** Medium | **Impact:** High  
**Mitigation:**
- Validate the `x-webhook-secret` header on every request (HMAC-SHA256 of the raw body against the shared secret stored in Key Vault).
- Rotate the shared secret every 90 days using an Azure Key Vault rotation policy.
- Enable Logic App IP restriction to allow only Azure DevOps IP ranges and your corporate egress IPs.
- Consider migrating to Azure API Management in front of the Logic App trigger for WAF, rate limiting, and OAuth 2.0.

### R-SEC-02 — Secrets in Logic App Parameters
**Risk:** Logic App runtime parameters marked `securestring` are not stored in plaintext in run history, but the parameter values are passed via Bicep during deployment, which may be logged in CI pipelines.  
**Mitigation:**
- Use Key Vault references for Logic App parameters: `@Microsoft.KeyVault(SecretUri=...)`.
- Ensure pipeline service principals have only `Key Vault Secrets User` (read-only) RBAC, not `Owner`.
- Enable Azure Policy to audit `securestring` parameter usage.

### R-SEC-03 — Teams Incoming Webhook URLs
**Risk:** Incoming webhook URLs for Teams channels are long-lived tokens embedded in routing-rules.json. If the storage account is compromised, an attacker can post arbitrary messages to Teams channels.  
**Mitigation:**
- Store webhook URLs as Key Vault secrets; store only the secret name in routing-rules.json.
- Enable private endpoint on the Storage Account; restrict access to the Function App and Logic App outbound IPs.
- Rotate webhook URLs quarterly.

### R-SEC-04 — Function App Authentication
**Risk:** The Rule Engine Azure Function is exposed over HTTPS. Although `authLevel: function` requires an API key, keys are static and can be enumerated.  
**Mitigation:**
- Use Managed Identity authentication: Logic App calls Function App with its system-assigned identity; Function validates the `Authorization: Bearer` token.
- Alternatively, place both in the same VNet and use private endpoints.

### R-SEC-05 — Storage Account Public Access
**Risk:** routing-rules.json contains distribution email addresses and Teams channel metadata. Public blob access would expose this.  
**Mitigation:** The Bicep deployment sets `allowBlobPublicAccess: false` and `minimumTlsVersion: TLS1_2`. Enforce this with Azure Policy.

---

## Operational

### R-OPS-01 — Logic App Throttling
**Risk:** Azure DevOps projects with high commit/PR volume can generate hundreds of work item events per minute. Logic Apps Consumption throttles at ~1,000 runs per minute per workflow.  
**Mitigation:**
- Place an Azure Service Bus queue between the ADO webhook and the Orchestrator.
- Use a Logic App trigger on the queue with a concurrency setting.
- Monitor `Throttled runs` metric in Application Insights.

### R-OPS-02 — Rule Engine Cold Start
**Risk:** The Azure Function on a Consumption plan can have cold starts of 2–5 seconds, adding latency to every notification.  
**Mitigation:**
- Use a Premium App Service Plan or Always Ready instances (Functions Flex Consumption).
- Cache `routing-rules.json` in memory with a 5-minute TTL to avoid redundant blob reads.

### R-OPS-03 — Teams Incoming Webhook Rate Limits
**Risk:** Microsoft Teams incoming webhooks are rate-limited at 4 requests/second per connector. Burst notifications for high-severity incidents can trigger `429 Too Many Requests`.  
**Mitigation:**
- Add exponential back-off with jitter in the Teams Notifier Logic App (retry policy: 3x, 5–60 s).
- Batch multiple notifications into a single Adaptive Card where the same rule matches multiple events.

### R-OPS-04 — SendGrid Delivery
**Risk:** Transient SendGrid API failures could silently drop critical notifications.  
**Mitigation:**
- Enable SendGrid Event Webhooks and write delivery events to Log Analytics.
- Alert on `delivered` rate dropping below 99%.
- Consider configuring a secondary email provider (e.g., Azure Communication Services Email) as a fallback.

### R-OPS-05 — Rule Configuration Errors
**Risk:** An invalid routing-rules.json (e.g., malformed JSON, missing required fields) uploaded to Blob Storage will cause all Rule Engine invocations to fail until corrected.  
**Mitigation:**
- Validate routing-rules.json against routing-schema.json in the CI pipeline before upload (use `ajv` or `jsonschema`).
- Implement a "last known good" pattern: keep the previous valid version of the rules file and fall back to it on parse failure.
- Add a smoke-test HTTP call in `upload-rules.ps1` to verify the Rule Engine can load the new rules.

---

## Technical Debt / Scalability

### R-TECH-01 — Logic Apps Consumption vs Standard
**Risk:** Logic Apps Consumption does not support VNet integration, inline JavaScript, or stateful sub-flows without workarounds.  
**Recommendation:** Migrate to **Logic Apps Standard** for production. Benefits: VNet integration, inline JavaScript (removes the need for a separate Function App), built-in versioning, better local development experience, and connection to private endpoints.

### R-TECH-02 — Hardcoded Scenario Logic
**Risk:** The scenarios (A/B/C) are currently determined by field values in the Rule Engine. Adding a new scenario requires a code change.  
**Recommendation:** Move scenario definitions into routing-rules.json as a `scenarios` array per rule. The Rule Engine can then be scenario-agnostic.

### R-TECH-03 — Salesforce Integration Gap
**Risk:** The POC covers ADO → notifications. The Salesforce Service Cloud sync requirement is not yet implemented.  
**Recommendation:** Add a Salesforce Logic App connector workflow that:
1. Receives the same ADO webhook.
2. Uses the Salesforce connector to upsert a Case or Custom Object.
3. Is triggered in parallel with the notification Orchestrator.

### R-TECH-04 — Rule Versioning
**Risk:** Updating routing-rules.json is a destructive operation — there is no history of who changed what.  
**Recommendation:** Enable Blob Storage versioning on the `routing-rules` container. Write a metadata record to a Log Analytics custom table on every rule update (source, timestamp, changed by).

### R-TECH-05 — Multi-Project Reuse
**Risk:** The Orchestrator currently extracts `resourceContainers.project.name` but routing rules are global. Two ADO projects with a product named "Ampla" will receive identical routing.  
**Recommendation:** Add an optional `adoProject` field to rule conditions. Default to `null` (match all projects). This allows project-scoped overrides without breaking existing rules.

---

## Recommendations Summary

| Priority | ID | Recommendation |
|----------|----|---------------|
| **P0** | R-SEC-01 | Implement HMAC webhook validation before going to production |
| **P0** | R-OPS-05 | Add JSON Schema validation to CI pipeline for rule uploads |
| **P1** | R-SEC-03 | Move Teams webhook URLs to Key Vault; store only secret names in config |
| **P1** | R-OPS-01 | Add Service Bus buffer for high-volume ADO projects |
| **P1** | R-TECH-01 | Plan migration to Logic Apps Standard before production rollout |
| **P2** | R-OPS-02 | Upgrade Function App plan to avoid cold starts |
| **P2** | R-TECH-04 | Enable Blob versioning for routing rules audit trail |
| **P3** | R-TECH-03 | Implement Salesforce sync workflow |
| **P3** | R-TECH-05 | Add `adoProject` field to rule conditions for multi-project isolation |
