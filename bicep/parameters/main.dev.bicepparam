using '../main.bicep'

param environmentName = 'dev'
param location = 'westus2'
param appName = 'notifypoc'
param logRetentionDays = 30
param notificationFromEmail = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com'
param adoOrganisationUrl = 'https://dev.azure.com/sbodhankar0209'

param tags = {
  environment: 'dev'
  application: 'enterprise-notification-routing'
  managedBy: 'bicep'
  costCenter: 'platform-engineering'
  costOptimisation: 'consumption-plan'
}
