@description('Function App name')
param functionAppName string

@description('App Service Plan name for the Function App')
param appServicePlanName string

@description('Azure region')
param location string

@description('Storage Account name (used by Functions runtime)')
param storageAccountName string

@description('Storage Account resource ID (for role assignments)')
param storageAccountId string

@description('Key Vault name (for Key Vault reference app settings)')
param keyVaultName string

@description('Application Insights connection string')
param appInsightsConnectionString string

@description('Resource tags')
param tags object = {}

// ---------------------------------------------------------------------------
// App Service Plan (Consumption — Y1)
// For production, upgrade to EP1 (Elastic Premium) to avoid cold starts
// ---------------------------------------------------------------------------
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: false   // false = Windows; set true for Linux
  }
}

// ---------------------------------------------------------------------------
// Function App
// ---------------------------------------------------------------------------
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.2'
      http20Enabled: true
      netFrameworkVersion: 'v6.0'
      nodeVersion: '~18'
      use32BitWorkerProcess: false
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};EndpointSuffix=${environment().suffixes.storage};AccountKey='
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};EndpointSuffix=${environment().suffixes.storage};AccountKey='
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~18'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: storageAccountName
        }
        {
          name: 'RULES_CONTAINER_NAME'
          value: 'routing-rules'
        }
        {
          name: 'RULES_BLOB_NAME'
          value: 'routing-rules.json'
        }
        // Key Vault reference — avoids storing connection string in app settings
        {
          name: 'STORAGE_CONNECTION_STRING'
          // Leave empty; use Managed Identity (STORAGE_ACCOUNT_NAME) in production
          value: ''
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Diagnostic settings — stream Function logs to Log Analytics
// ---------------------------------------------------------------------------
resource funcDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${functionAppName}'
  scope: functionApp
  properties: {
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppHostname string = functionApp.properties.defaultHostName

// Note: Function key is retrieved post-deploy via az functionapp keys list
output ruleEngineUrl string = 'https://${functionApp.properties.defaultHostName}/api/evaluate-rules?code=REPLACE_WITH_FUNCTION_KEY'
