@description('Application Insights resource name')
param appInsightsName string

@description('Log Analytics Workspace resource name')
param logAnalyticsName string

@description('Azure region')
param location string

@description('Data retention in days (30-730)')
@minValue(30)
@maxValue(730)
param retentionDays int = 90

@description('Resource tags')
param tags object = {}

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// ---------------------------------------------------------------------------
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: 1    // Adjust for production workloads
    }
  }
}

// ---------------------------------------------------------------------------
// Application Insights (workspace-based)
// ---------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: retentionDays
  }
}

// ---------------------------------------------------------------------------
// Alert Rules
// ---------------------------------------------------------------------------
// NOTE: Add metric alerts post-deployment once Logic App resource IDs are known.
// Example: az monitor metrics alert create --scopes <orchestratorLaId> ...

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output instrumentationKey string = appInsights.properties.InstrumentationKey
output connectionString string = appInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
