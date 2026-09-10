@description('Environment name: dev, staging, or prod')
@allowed(['dev', 'staging', 'prod'])
param environmentName string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short application name used in resource naming')
@maxLength(10)
param appName string = 'notifypoc'

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

@description('Service account email for the SharePoint API connection')
param sharePointServiceAccountEmail string = teamsServiceAccountEmail

@description('SharePoint site hosting routing-rules.json')
param sharePointSiteUrl string = 'https://mngenvmcap628198.sharepoint.com/sites/demosite'

@description('Site-relative path to routing-rules.json')
param sharePointRulesFilePath string = '/Shared Documents/routing-rules.json'

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
    sendGridApiKey: sendGridApiKey
    notificationFromEmail: notificationFromEmail
    adoOrganisationUrl: adoOrganisationUrl
    teamsServiceAccountEmail: teamsServiceAccountEmail
    sharePointServiceAccountEmail: sharePointServiceAccountEmail
    sharePointSiteUrl: sharePointSiteUrl
    sharePointRulesFilePath: sharePointRulesFilePath
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
