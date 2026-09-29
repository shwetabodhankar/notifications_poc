@description('Orchestrator Logic App name')
param orchestratorLaName string

@description('Dispatcher Logic App name')
param dispatcherLaName string

@description('Teams Notifier Logic App name')
param teamsNotifierLaName string

@description('Email Notifier Logic App name')
param emailNotifierLaName string

@description('Azure region')
param location string

@description('Microsoft 365 mailbox used by Microsoft Graph to send notifications')
param notificationFromEmail string

@description('Azure DevOps organisation base URL, e.g. https://dev.azure.com/myorg')
param adoOrganisationUrl string = 'https://dev.azure.com'

@description('Log Analytics Workspace resource ID for diagnostic settings')
param logAnalyticsWorkspaceId string

@description('Service account email used to authenticate the Teams API connection (e.g. svc-notify@company.com)')
param teamsServiceAccountEmail string = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com'

@description('Service account email used to authenticate the SharePoint API connection')
param sharePointServiceAccountEmail string = teamsServiceAccountEmail

@description('SharePoint site hosting the routing rules list')
param sharePointSiteUrl string = 'https://mngenvmcap628198.sharepoint.com/sites/demosite'

@description('ID of the SharePoint routing rules list')
param sharePointRulesListId string = 'd65d5f16-b5d4-499e-bb16-baa6aac5ac0b'

@description('Resource tags')
param tags object = {}

var teamsConnectionName = 'conn-teams-${teamsNotifierLaName}'
var teamsConnectorLaName = '${teamsNotifierLaName}-connector'
var sharePointConnectionName = 'conn-sharepoint-${orchestratorLaName}'

// ---------------------------------------------------------------------------
// Teams API Connection (service account — must be authorized post-deploy)
// ---------------------------------------------------------------------------
resource teamsConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: teamsConnectionName
  location: location
  tags: tags
  properties: {
    displayName: teamsServiceAccountEmail
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams')
    }
  }
}

// ---------------------------------------------------------------------------
// Teams Notifier — Connector variant (service account via API connection)
// ---------------------------------------------------------------------------
resource teamsConnectorLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: teamsConnectorLaName
  location: location
  tags: tags
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../../logic-apps/teams-notifier-connector.json')
    parameters: {
      '$connections': {
        value: {
          teams: {
            connectionId: teamsConnection.id
            connectionName: teamsConnectionName
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams')
          }
        }
      }
    }
  }
}

resource teamsConnectorDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${teamsConnectorLaName}'
  scope: teamsConnectorLogicApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [ { category: 'WorkflowRuntime', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

// ---------------------------------------------------------------------------
// Email Notifier Logic App
// ---------------------------------------------------------------------------
resource emailNotifierLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: emailNotifierLaName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../../logic-apps/email-notifier.json')
    parameters: {
      emailFromAddress: {
        value: notificationFromEmail
      }
      emailFromName: {
        value: 'Azure DevOps Notifications'
      }
      adoBaseUrl: {
        value: adoOrganisationUrl
      }
    }
  }
}

resource emailNotifierDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${emailNotifierLaName}'
  scope: emailNotifierLogicApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'WorkflowRuntime'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Dispatcher Logic App
// ---------------------------------------------------------------------------
resource dispatcherLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: dispatcherLaName
  location: location
  tags: tags
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../../logic-apps/dispatcher.json')
    parameters: {
      teamsNotifierUrl: {
        value: listCallbackUrl(
          '${teamsConnectorLogicApp.id}/triggers/Receive_Teams_Notification_Request',
          '2019-05-01'
        ).value
      }
      emailNotifierUrl: {
        value: listCallbackUrl(
          '${emailNotifierLogicApp.id}/triggers/Receive_Email_Notification_Request',
          '2019-05-01'
        ).value
      }
    }
  }
}

resource dispatcherDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${dispatcherLaName}'
  scope: dispatcherLogicApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'WorkflowRuntime'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Orchestrator Logic App
// ---------------------------------------------------------------------------
resource sharePointConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: sharePointConnectionName
  location: location
  tags: tags
  properties: {
    displayName: sharePointServiceAccountEmail
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sharepointonline')
    }
  }
}

resource orchestratorLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: orchestratorLaName
  location: location
  tags: tags
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../../logic-apps/orchestrator.json')
    parameters: {
      '$connections': {
        value: {
          sharepointonline: {
            connectionId: sharePointConnection.id
            connectionName: sharePointConnectionName
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sharepointonline')
          }
        }
      }
      sharePointSiteUrl: {
        value: sharePointSiteUrl
      }
      sharePointRulesListId: {
        value: sharePointRulesListId
      }
      dispatcherCallbackUrl: {
        value: listCallbackUrl(
          '${dispatcherLogicApp.id}/triggers/Receive_Dispatch_Request',
          '2019-05-01'
        ).value
      }
      correlationIdPrefix: {
        value: 'NOTIF'
      }
    }
  }
}

resource orchestratorDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${orchestratorLaName}'
  scope: orchestratorLogicApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'WorkflowRuntime'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output orchestratorEndpoint string = listCallbackUrl(
  '${orchestratorLogicApp.id}/triggers/Receive_WorkItem_Webhook',
  '2019-05-01'
).value

output teamsConnectorLogicAppName string = teamsConnectorLaName
output teamsConnectionName string = teamsConnectionName
output sharePointConnectionName string = sharePointConnectionName
output emailNotifierPrincipalId string = emailNotifierLogicApp.identity.principalId
