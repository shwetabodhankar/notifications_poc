# Risks and Recommendations

## Signed Callback URL Exposure

**Risk:** Anyone who obtains the complete Orchestrator callback URL can invoke the workflow.

**Recommendations:**

- Treat the complete URL as a credential.
- Keep it out of source control, tickets, screenshots, and shared logs.
- Regenerate the trigger signature after suspected exposure.
- For production, consider API Management with Entra ID, rate limiting, and request validation.

## SharePoint Connector Identity

**Risk:** Routing fails if the connector account loses its license, site permission, consent, or valid session.

**Recommendations:**

- Use a dedicated managed service account.
- Grant read-only access to the routing document.
- Monitor API connection health and reauthorize after identity-policy changes.

## Teams Connector Identity

**Risk:** Notifications fail if the connector account cannot access a destination Team or channel.

**Recommendations:**

- Add the connector account to every destination Team.
- Add it explicitly to private channels.
- Test each Team/channel ID after routing changes.
- Monitor `Post_To_Teams_Channel` failures.

## Routing Configuration Quality

**Risk:** Invalid or overlapping rules can stop processing or send duplicate notifications.

**Recommendations:**

- Run `./scripts/validate-rules.ps1` before uploading a changed file.
- Use SharePoint version history and restricted editor permissions.
- Review overlapping conditions and priority ordering.
- Test representative standard, P1, cybersecurity, and catch-all events.

## SharePoint Availability

**Risk:** The Orchestrator reads the routing document for every event, so SharePoint or connector outages block routing.

**Recommendations:**

- Keep the existing exponential retry policy.
- Alert on failed `Load_Routing_Rules` actions.
- Consider caching a last-known-good rules document if production availability requires it.

## Duplicate Events

**Risk:** Azure DevOps can deliver repeated updates and retries, resulting in duplicate notifications.

**Recommendations:**

- Add idempotency using the Azure DevOps event ID if duplicate suppression is required.
- Add update filters in Service Hooks where practical.

## Multiple Matching Rules

**Risk:** A single work item may intentionally or accidentally match several rules.

**Recommendations:**

- Treat multiple matches as expected unless exclusive routing is required.
- Add a stop-after-first-match policy only if the business rules demand it.
- Include rule ID and rule name in notifications for traceability.

## Email Delivery

**Risk:** SendGrid credentials can expire or be exposed, and sender addresses may not be verified.

**Recommendations:**

- Supply the API key as a secure deployment parameter.
- Use a verified sender/domain.
- Rotate the key and avoid logging it.
- Disable email routes when SendGrid is intentionally not configured.
