// =============================================================================
// managed-identities.bicep — Deploy FIRST before all other templates
//
// Defines all managed identities for the willbracken platform.
// Deterministic names (no suffix) so other templates can reference via 'existing'.
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file managed-identities.bicep
//
// Then pass outputs to other templates:
//   --parameters platformIdentityId=<output> platformIdentityPrincipalId=<output>
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Short base name — must match baseName in always-free-extended.bicep')
param baseName string = 'willbracken'

// ── Platform Identity ─────────────────────────────────────────────────────────
// Shared by: App Services, Container Apps, APIM, n8n (via env var), any workload
// that needs to read Key Vault secrets, App Config, or Service Bus queues.
// All authentication flows through this identity — no rotating passwords.
resource platformIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${baseName}-platform-id'
  location: location
  tags: {
    purpose: 'shared-platform-auth'
    managedBy: 'managed-identities.bicep'
  }
}

// ── Bot Identity ──────────────────────────────────────────────────────────────
// Dedicated to Azure Bot Service — Azure requires a separate app registration
// per bot and it cannot share the platform identity.
resource botIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${baseName}-bot-id'
  location: location
  tags: {
    purpose: 'bot-service-auth'
    managedBy: 'managed-identities.bicep'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
// Use these as --parameters inputs when deploying other templates.

output platformIdentityId string = platformIdentity.id
output platformIdentityClientId string = platformIdentity.properties.clientId
output platformIdentityPrincipalId string = platformIdentity.properties.principalId
output platformIdentityName string = platformIdentity.name

output botIdentityId string = botIdentity.id
output botIdentityClientId string = botIdentity.properties.clientId
output botIdentityPrincipalId string = botIdentity.properties.principalId
output botIdentityName string = botIdentity.name
