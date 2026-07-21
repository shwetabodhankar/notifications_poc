@description('Environment name: dev, staging, or prod')
@allowed(['dev', 'staging', 'prod'])
param environmentName string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short application name used in resource naming')
@maxLength(10)
param appName string = 'notifpoc'

@description('Azure DevOps webhook shared secret — stored in Key Vault post-deploy')
@secure()
param webhookSharedSecret string

@description('SendGrid API key for email delivery. Leave as default placeholder to skip email — Teams notifications still work.')
@secure()
param sendGridApiKey string = 'SENDGRID_NOT_CONFIGURED'

@description('Email address used as the From address for notifications')
param notificationFromEmail string = 'notifications@company.com'

@description('Log Analytics workspace retention in days')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

@description('Azure DevOps organisation base URL, e.g. https://dev.azure.com/myorg')
param adoOrganisationUrl string = 'https://dev.azure.com'

@description('Service account email for the Teams API connection')
param teamsServiceAccountEmail string = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com'

@description('Tags applied to all resources')
param tags object = {
  environment: environmentName
  application: 'enterprise-notification-routing'
  managedBy: 'bicep'
  costCenter: 'platform-engineering'
}

// ---------------------------------------------------------------------------
// Naming convention: <type>-<app>-<env>
// 4-char suffix derived from subscription ID ensures globally-unique names
// when the same appName+env is deployed to multiple subscriptions.
// ---------------------------------------------------------------------------
var uniqueSuffix          = take(uniqueString(subscription().subscriptionId), 4)
var storageAccountBaseName = replace('st${appName}${environmentName}', '-', '')
var storageAccountName     = '${storageAccountBaseName}${uniqueSuffix}'
var keyVaultName           = 'kv-${appName}-${environmentName}-${uniqueSuffix}'
var appInsightsName = 'appi-${appName}-${environmentName}'
var logAnalyticsName = 'law-${appName}-${environmentName}'
var orchestratorLaName = 'la-notif-orchestrator-${environmentName}'
var dispatcherLaName = 'la-notif-dispatcher-${environmentName}'
var teamsNotifierLaName = 'la-notif-teams-${environmentName}'
var emailNotifierLaName = 'la-notif-email-${environmentName}'

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

module storage './modules/storage.bicep' = {
  name: 'storage-${environmentName}'
  params: {
    storageAccountName: storageAccountName
    location: location
    tags: tags
  }
}

module keyVault './modules/keyvault.bicep' = {
  name: 'keyvault-${environmentName}'
  params: {
    keyVaultName: keyVaultName
    location: location
    tags: tags
    webhookSharedSecret: webhookSharedSecret
    sendGridApiKey: sendGridApiKey
  }
}

module appInsights './modules/app-insights.bicep' = {
  name: 'appinsights-${environmentName}'
  params: {
    appInsightsName: appInsightsName
    logAnalyticsName: logAnalyticsName
    location: location
    retentionDays: logRetentionDays
    tags: tags
  }
}

module logicApps './modules/logic-apps.bicep' = {
  name: 'logicapps-${environmentName}'
  params: {
    orchestratorLaName: orchestratorLaName
    dispatcherLaName: dispatcherLaName
    teamsNotifierLaName: teamsNotifierLaName
    emailNotifierLaName: emailNotifierLaName
    location: location
    storageAccountName: storageAccountName
    webhookSharedSecret: webhookSharedSecret
    sendGridApiKey: sendGridApiKey
    notificationFromEmail: notificationFromEmail
    adoOrganisationUrl: adoOrganisationUrl
    teamsServiceAccountEmail: teamsServiceAccountEmail
    logAnalyticsWorkspaceId: appInsights.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
  dependsOn: [
    keyVault
    appInsights
  ]
}

// Grant each Logic App's Managed Identity read access to the routing-rules blob container
module laStorageRoleAssignment './modules/role-assignment.bicep' = {
  name: 'la-storage-rbac-${environmentName}'
  params: {
    principalIds: logicApps.outputs.logicAppPrincipalIds
    storageAccountId: storage.outputs.storageAccountId
    roleName: 'Storage Blob Data Reader'
  }
  dependsOn: [ logicApps, storage ]
}

// Grant each Logic App's Managed Identity Key Vault Secrets access
module laKvRoleAssignment './modules/role-assignment.bicep' = {
  name: 'la-kv-rbac-${environmentName}'
  params: {
    principalIds: logicApps.outputs.logicAppPrincipalIds
    keyVaultId: keyVault.outputs.keyVaultId
    roleName: 'Key Vault Secrets User'
  }
  dependsOn: [ logicApps, keyVault ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output orchestratorTriggerEndpoint string = logicApps.outputs.orchestratorEndpoint
output dispatcherTriggerEndpoint string = logicApps.outputs.dispatcherEndpoint
output storageAccountName string = storage.outputs.storageAccountName
output keyVaultName string = keyVault.outputs.keyVaultName
output appInsightsName string = appInsights.outputs.appInsightsName
output teamsConnectorLogicAppName string = logicApps.outputs.teamsConnectorLogicAppName
output teamsConnectionName string = logicApps.outputs.teamsConnectionName
