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

@description('Storage Account name hosting routing-rules.json')
param storageAccountName string

@description('ADO webhook shared secret used to validate incoming webhook calls')
@secure()
param webhookSharedSecret string

@description('SendGrid API key')
@secure()
param sendGridApiKey string

@description('Notification from email address')
param notificationFromEmail string

@description('Azure DevOps organisation base URL, e.g. https://dev.azure.com/myorg')
param adoOrganisationUrl string = 'https://dev.azure.com'

@description('Log Analytics Workspace resource ID for diagnostic settings')
param logAnalyticsWorkspaceId string

@description('Service account email used to authenticate the Teams API connection (e.g. svc-notify@company.com)')
param teamsServiceAccountEmail string = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com'

@description('Resource tags')
param tags object = {}

var teamsConnectionName = 'conn-teams-${teamsNotifierLaName}'
var teamsConnectorLaName = '${teamsNotifierLaName}-connector'

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
  identity: {
    type: 'SystemAssigned'
  }
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
// Teams Notifier Logic App (deployed first — no dependencies on other LAs)
// ---------------------------------------------------------------------------
resource teamsNotifierLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: teamsNotifierLaName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../../logic-apps/teams-notifier.json')
    parameters: {}
  }
}

resource teamsNotifierDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${teamsNotifierLaName}'
  scope: teamsNotifierLogicApp
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
      sendGridApiKey: {
        value: sendGridApiKey
      }
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
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../../logic-apps/dispatcher.json')
    parameters: {
      teamsNotifierUrl: {
        value: listCallbackUrl(
          '${teamsNotifierLogicApp.id}/triggers/Receive_Teams_Notification_Request',
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
  dependsOn: [
    teamsNotifierLogicApp
    emailNotifierLogicApp
  ]
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
resource orchestratorLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: orchestratorLaName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('../../logic-apps/orchestrator.json')
    parameters: {
      storageAccountName: {
        value: storageAccountName
      }
      dispatcherCallbackUrl: {
        value: listCallbackUrl(
          '${dispatcherLogicApp.id}/triggers/Receive_Dispatch_Request',
          '2019-05-01'
        ).value
      }
      webhookSharedSecret: {
        value: webhookSharedSecret
      }
      correlationIdPrefix: {
        value: 'NOTIF'
      }
    }
  }
  dependsOn: [
    dispatcherLogicApp
  ]
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

output dispatcherEndpoint string = listCallbackUrl(
  '${dispatcherLogicApp.id}/triggers/Receive_Dispatch_Request',
  '2019-05-01'
).value

output logicAppPrincipalIds array = [
  orchestratorLogicApp.identity.principalId
  dispatcherLogicApp.identity.principalId
  teamsNotifierLogicApp.identity.principalId
  teamsConnectorLogicApp.identity.principalId
  emailNotifierLogicApp.identity.principalId
]

output teamsConnectorLogicAppName string = teamsConnectorLaName
output teamsConnectionName string = teamsConnectionName
