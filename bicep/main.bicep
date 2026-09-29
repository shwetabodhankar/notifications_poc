@description('Environment name: dev, staging, or prod')
@allowed(['dev', 'staging', 'prod'])
param environmentName string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short application name used in resource naming')
@maxLength(10)
param appName string = 'notifypoc'

@description('Microsoft 365 mailbox used by Microsoft Graph to send notifications')
param notificationFromEmail string = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com'

@description('Log Analytics workspace retention in days')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

@description('Azure DevOps organisation base URL, e.g. https://dev.azure.com/myorg')
param adoOrganisationUrl string = 'https://dev.azure.com'

@description('Service account email for the Teams API connection')
param teamsServiceAccountEmail string = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com'

@description('Service account email for the SharePoint API connection')
param sharePointServiceAccountEmail string = teamsServiceAccountEmail

@description('SharePoint site hosting the routing rules list')
param sharePointSiteUrl string = 'https://mngenvmcap628198.sharepoint.com/sites/demosite'

@description('ID of the SharePoint routing rules list')
param sharePointRulesListId string = 'd65d5f16-b5d4-499e-bb16-baa6aac5ac0b'

@description('Tags applied to all resources')
param tags object = {
  environment: environmentName
  application: 'enterprise-notification-routing'
  managedBy: 'bicep'
  costCenter: 'platform-engineering'
}

// ---------------------------------------------------------------------------
// Naming convention: <type>-<app>-<env>
// ---------------------------------------------------------------------------
var appInsightsName = 'appi-${appName}-${environmentName}'
var logAnalyticsName = 'law-${appName}-${environmentName}'
var orchestratorLaName = 'la-notif-orchestrator-${environmentName}'
var dispatcherLaName = 'la-notif-dispatcher-${environmentName}'
var teamsNotifierLaName = 'la-notif-teams-${environmentName}'
var emailNotifierLaName = 'la-notif-email-${environmentName}'

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

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
    notificationFromEmail: notificationFromEmail
    adoOrganisationUrl: adoOrganisationUrl
    teamsServiceAccountEmail: teamsServiceAccountEmail
    sharePointServiceAccountEmail: sharePointServiceAccountEmail
    sharePointSiteUrl: sharePointSiteUrl
    sharePointRulesListId: sharePointRulesListId
    logAnalyticsWorkspaceId: appInsights.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output orchestratorTriggerEndpoint string = logicApps.outputs.orchestratorEndpoint
output appInsightsName string = appInsights.outputs.appInsightsName
output teamsConnectorLogicAppName string = logicApps.outputs.teamsConnectorLogicAppName
output teamsConnectionName string = logicApps.outputs.teamsConnectionName
output sharePointConnectionName string = logicApps.outputs.sharePointConnectionName
output emailNotifierPrincipalId string = logicApps.outputs.emailNotifierPrincipalId
