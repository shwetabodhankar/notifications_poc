@description('Storage account name (globally unique, 3-24 alphanumeric lowercase)')
param storageAccountName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('Name of the Blob container for routing rules')
param rulesContainerName string = 'routing-rules'

// ---------------------------------------------------------------------------
// Storage Account
// ---------------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
    encryption: {
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
      keySource: 'Microsoft.Storage'
    }
    networkAcls: {
      defaultAction: 'Allow'  // Restrict to VNet in production (see risks doc)
      bypass: 'AzureServices'
    }
  }
}

// Blob service with versioning and soft-delete for routing rules audit trail
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// Container for routing rules JSON
resource rulesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: rulesContainerName
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'notification-routing-rules'
    }
  }
}

// Container for dead-letter events (failed processing)
resource deadLetterContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'dead-letter'
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'failed-event-replay'
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output rulesContainerName string = rulesContainer.name
output primaryEndpoint string = storageAccount.properties.primaryEndpoints.blob
