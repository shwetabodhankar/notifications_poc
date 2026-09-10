using '../main.bicep'

param environmentName = 'dev'
param location = 'westus2'
param appName = 'notifypoc'
param logRetentionDays = 30
param notificationFromEmail = 'notifications-dev@company.com'

// sendGridApiKey is optional — omit it to skip email; Teams notifications still work.
// Supply at deploy time: az deployment group create --parameters sendGridApiKey=$env:SENDGRID_KEY
// Do NOT commit real secret values to source control
// Example:
//   az deployment group create ... \
//     --parameters webhookSharedSecret="$env:WEBHOOK_SECRET" \
//     --parameters sendGridApiKey="$env:SENDGRID_KEY"
param adoOrganisationUrl = 'https://dev.azure.com/sbodhankar0209'
param webhookSharedSecret = 'REPLACE_AT_DEPLOY_TIME'
param sendGridApiKey = 'REPLACE_AT_DEPLOY_TIME'

param tags = {
  environment: 'dev'
  application: 'enterprise-notification-routing'
  managedBy: 'bicep'
  costCenter: 'platform-engineering'
  costOptimisation: 'consumption-plan'
}
