@description('Key Vault name (3-24 chars, globally unique)')
param keyVaultName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('Azure AD tenant ID')
param tenantId string = subscription().tenantId

@description('Webhook shared secret for ADO webhook validation')
@secure()
param webhookSharedSecret string

@description('SendGrid API key for email delivery. Defaults to placeholder when not provided.')
@secure()
param sendGridApiKey string = 'SENDGRID_NOT_CONFIGURED'

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: true    // Use RBAC, not access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    networkAcls: {
      defaultAction: 'Allow'         // Restrict to VNet in production
      bypass: 'AzureServices'
    }
  }
}

// ---------------------------------------------------------------------------
// Secrets
// ---------------------------------------------------------------------------
resource secretWebhook 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'webhookSharedSecret'
  properties: {
    value: webhookSharedSecret
    attributes: {
      enabled: true
    }
    contentType: 'text/plain'
  }
}

resource secretSendGrid 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'sendGridApiKey'
  properties: {
    value: sendGridApiKey
    attributes: {
      enabled: true
    }
    contentType: 'text/plain'
  }
}

// Placeholder for Logic App dispatcher URL (populated post-deploy)
resource secretDispatcherUrl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'dispatcherCallbackUrl'
  properties: {
    value: 'PLACEHOLDER — update after Logic App deployment'
    attributes: {
      enabled: true
    }
    contentType: 'text/plain'
  }
}

// Placeholder for Rule Engine URL (populated post-deploy)
resource secretRuleEngineUrl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ruleEngineUrl'
  properties: {
    value: 'PLACEHOLDER — update after Function App deployment'
    attributes: {
      enabled: true
    }
    contentType: 'text/plain'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output webhookSecretUri string = secretWebhook.properties.secretUri
output sendGridSecretUri string = secretSendGrid.properties.secretUri
