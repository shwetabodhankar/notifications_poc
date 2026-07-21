@description('Principal ID of the resource receiving the role assignment')
param principalId string = ''

@description('Array of principal IDs (when assigning to multiple principals)')
param principalIds array = []

@description('Storage Account resource ID (when assigning storage roles)')
param storageAccountId string = ''

@description('Key Vault resource ID (when assigning Key Vault roles)')
param keyVaultId string = ''

@description('Role name to assign')
@allowed([
  'Storage Blob Data Reader'
  'Storage Blob Data Contributor'
  'Key Vault Secrets User'
  'Key Vault Secrets Officer'
])
param roleName string

// Built-in role definition IDs
var roleDefinitionIds = {
  'Storage Blob Data Reader': '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  'Storage Blob Data Contributor': 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  'Key Vault Secrets User': '4633458b-17de-408a-b874-0445c86b69e6'
  'Key Vault Secrets Officer': 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
}

var targetResourceId = !empty(storageAccountId) ? storageAccountId : keyVaultId
var effectivePrincipalIds = !empty(principalId) ? [principalId] : principalIds

// Assign role to each principal
resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in effectivePrincipalIds: {
    name: guid(targetResourceId, pid, roleDefinitionIds[roleName])
    scope: resourceGroup()
    properties: {
      roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionIds[roleName])
      principalId: pid
      principalType: 'ServicePrincipal'
    }
  }
]
