using '../main.bicep'

param environmentName = 'prod'
param location = 'eastus'
param appName = 'notifpoc'
param logRetentionDays = 90
param notificationFromEmail = 'notifications@company.com'

// Secrets are injected by the CI/CD pipeline from Azure Key Vault or
// a secrets management tool — never committed to source control
param adoOrganisationUrl = 'https://dev.azure.com/sbodhankar0209'
param webhookSharedSecret = 'REPLACE_AT_DEPLOY_TIME'
param sendGridApiKey = 'REPLACE_AT_DEPLOY_TIME'

param tags = {
  environment: 'prod'
  application: 'enterprise-notification-routing'
  managedBy: 'bicep'
  costCenter: 'platform-engineering'
  sla: '99.9'
  dataClassification: 'internal'
}
