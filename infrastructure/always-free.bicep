// =============================================================================
// always-free.bicep — Core always-free Azure services
//
// Cosmos DB + Storage Account (always free).
// Function App on Consumption plan (optional — skip if Dynamic VM quota = 0).
//
// Quota notes:
//   • F1 App Service Plan removed — it belongs in app-services.bicep, not here
//   • If Dynamic VM quota = 0: set deployFunctionApp=false, deploy storage+cosmos only
//     Then request quota increase: portal → Subscriptions → Usage + Quotas → Request
//   • Cosmos DB: limit 1 free-tier per subscription
//
// Requires: managed-identities.bicep deployed first.
//
// Deploy (full):
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file always-free.bicep \
//     --parameters platformIdentityId=<from managed-identities output>
//
// Deploy (skip Function App if quota error):
//   az deployment group create ... --parameters platformIdentityId=<id> deployFunctionApp=false
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param baseName string = 'willbracken'

@description('Resource ID of the platform user-assigned identity (from managed-identities.bicep output)')
param platformIdentityId string

@description('Set false if Dynamic VM quota is 0 — deploys Cosmos + Storage only')
param deployFunctionApp bool = true

@description('Set false if a free-tier Cosmos DB already exists in this subscription (limit: 1 per subscription)')
param deployCosmosDb bool = true

var uniqueSuffix = take(uniqueString(resourceGroup().id), 6)

// Guaranteed min-length storage name — satisfies BCP334 static analysis
var storageAccountName = 'wbfn${uniqueSuffix}stor'

// Built-in role IDs for identity-based storage auth
var roleStorageBlobDataOwner        = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleStorageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleStorageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// Reference platform identity
resource platformIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: last(split(platformIdentityId, '/'))
}

// ── Cosmos DB (Free Tier) ─────────────────────────────────────────────────────
// 1 per subscription. 1000 RU/s + 25GB free forever.
// Set deployCosmosDb=false if a free-tier account already exists in this subscription.
// Find existing: portal → Azure Cosmos DB → filter by subscription.
resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = if (deployCosmosDb) {
  name: '${baseName}-cosmos-${uniqueSuffix}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: true
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    disableLocalAuth: false
  }
}

// ── Storage Account ───────────────────────────────────────────────────────────
// Always free within 5GB. Used by Functions runtime (blobs, queues, tables).
// Also usable by n8n workflows for file staging and by App Config as backup store.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// ── Function App Consumption Plan ─────────────────────────────────────────────
// Y1/Dynamic — free for first 1M executions/month.
// Skipped if deployFunctionApp=false (quota workaround).
resource consumptionPlan 'Microsoft.Web/serverfarms@2023-01-01' = if (deployFunctionApp) {
  name: '${baseName}-consumption'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true   // Required for Linux
  }
}

// ── Function App ───────────────────────────────────────────────────────────────
// Identity-based storage auth — no connection string, no key rotation risk.
// Both system identity (for storage RBAC) and platform identity (for KV/AppConfig).
resource functionApp 'Microsoft.Web/sites@2023-01-01' = if (deployFunctionApp) {
  name: '${baseName}-func-${uniqueSuffix}'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${platformIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: consumptionPlan.id
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccountName
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: platformIdentity.properties.clientId
        }
      ]
    }
    httpsOnly: true
  }
}

// ── RBAC: Function App system identity → Storage ───────────────────────────────
// Only created when Function App is deployed.

resource funcStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFunctionApp) {
  name: guid(storageAccount.id, '${baseName}-func', roleStorageBlobDataOwner)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataOwner)
    principalId: deployFunctionApp ? any(functionApp).identity.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFunctionApp) {
  name: guid(storageAccount.id, '${baseName}-func', roleStorageQueueDataContributor)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageQueueDataContributor)
    principalId: deployFunctionApp ? any(functionApp).identity.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployFunctionApp) {
  name: guid(storageAccount.id, '${baseName}-func', roleStorageTableDataContributor)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageTableDataContributor)
    principalId: deployFunctionApp ? any(functionApp).identity.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output storageAccountName string = storageAccount.name
output cosmosDbEndpoint string = deployCosmosDb ? any(cosmosDb).properties.documentEndpoint : 'existing-cosmos-not-referenced'
output functionAppName string = deployFunctionApp ? any(functionApp).name : 'not-deployed'
output functionAppPrincipalId string = deployFunctionApp ? any(functionApp).identity.principalId : 'not-deployed'
