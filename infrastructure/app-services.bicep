// =============================================================================
// app-services.bicep — App Service web apps (F1 free tier)
//
// Python API + Node.js API on Linux F1.
// Both use the platform managed identity for Key Vault secret access.
//
// Requires: managed-identities.bicep + always-free-extended.bicep deployed first.
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file app-services.bicep \
//     --parameters platformIdentityId=<id> keyVaultName=<kv-name>
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param pythonAppName string = 'willbracken-python-api'
param nodeAppName string = 'willbracken-node-api'

@description('Resource ID of the platform user-assigned identity (from managed-identities.bicep)')
param platformIdentityId string

@description('Name of the Key Vault created by always-free-extended.bicep')
param keyVaultName string

@description('Set false if Free VM quota is 0 — skip App Service deployment until quota is granted')
param deployAppServices bool = true

// Built-in role ID
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

// Reference existing Key Vault for RBAC scope
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Reference platform identity
resource platformIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: last(split(platformIdentityId, '/'))
}

// ── App Service Plan (F1 — Free, Linux) ───────────────────────────────────────
resource freeAppServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = if (deployAppServices) {
  name: 'willbracken-free-asp'
  location: location
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  properties: {
    reserved: true
  }
}

// ── Python App Service ────────────────────────────────────────────────────────
// Uses platform identity to pull secrets from Key Vault at runtime.
// @Microsoft.KeyVault(VaultName=...;SecretName=...) is the correct reference syntax.
resource pythonApp 'Microsoft.Web/sites@2023-01-01' = if (deployAppServices) {
  name: pythonAppName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${platformIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: freeAppServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      // AZURE_CLIENT_ID tells DefaultAzureCredential which identity to use
      // when multiple user-assigned identities exist on the resource
      appSettings: [
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: platformIdentity.properties.clientId
        }
        // Key Vault references — these resolve at app startup using the assigned identity.
        // Replace SecretName values with your actual secret names.
        {
          name: 'DATABASE_URL'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=database-url)'
        }
        {
          name: 'COSMOS_DB_CONN'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=cosmos-connection-string)'
        }
        {
          name: 'SUPABASE_URL'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=supabase-url)'
        }
        {
          name: 'SUPABASE_KEY'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=supabase-anon-key)'
        }
      ]
    }
  }
}

// ── Node.js App Service ───────────────────────────────────────────────────────
resource nodeApp 'Microsoft.Web/sites@2023-01-01' = if (deployAppServices) {
  name: nodeAppName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${platformIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: freeAppServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|22-lts'
      appSettings: [
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: platformIdentity.properties.clientId
        }
        {
          name: 'SERVICEBUS_CONNECTION'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=servicebus-connection-string)'
        }
      ]
    }
  }
}

// ── RBAC: Platform Identity → Key Vault ───────────────────────────────────────
// Both app services share the platform identity, so one role assignment covers both.
// Scoped to Key Vault — not subscription-level, minimal privilege.
resource kvSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAppServices) {
  name: guid(keyVault.id, platformIdentity.id, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: platformIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output pythonAppUrl string = deployAppServices ? 'https://${any(pythonApp).properties.defaultHostName}' : 'not-deployed'
output nodeAppUrl string = deployAppServices ? 'https://${any(nodeApp).properties.defaultHostName}' : 'not-deployed'
