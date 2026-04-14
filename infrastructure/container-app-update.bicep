// =============================================================================
// infrastructure/container-app-update.bicep
//
// Updates the existing willbracken-app Container App with the AI router image.
// Uses the existing willbracken-cae environment (not recreated).
// Secrets pulled from Key Vault via willbracken-platform-id managed identity.
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file infrastructure/container-app-update.bicep \
//     --parameters containerImage=<registry>/ai-router:<tag>
// =============================================================================

@description('Azure region — defaults to resource group location')
param location string = resourceGroup().location

@description('Container image to deploy (e.g. ghcr.io/willbracken/ai-router:latest)')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Name of the existing Container App')
param containerAppName string = 'willbracken-app'

@description('Name of the existing Container App Environment')
param containerAppEnvName string = 'willbracken-cae'

@description('Name of the existing Key Vault')
param keyVaultName string = 'willbracken-kv-ihe42a'

@description('Resource ID of the user-assigned managed identity')
param managedIdentityName string = 'willbracken-platform-id'

// ── Reference existing resources (no re-creation) ────────────────────────────

resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: containerAppEnvName
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: managedIdentityName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// ── Container App (update) ────────────────────────────────────────────────────
// Key Vault secret references require the secretUri to point to the versioned
// or versionless URI. We use the versionless URI so new secret versions are
// picked up on the next revision without a Bicep re-deploy.

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    environmentId: containerAppEnv.id

    // ── Secrets (Key Vault references via managed identity) ───────────────────
    configuration: {
      secrets: [
        {
          name: 'anthropic-api-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/anthropic-api-key'
          identity: managedIdentity.id
        }
        {
          name: 'openai-api-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/openai-api-key'
          identity: managedIdentity.id
        }
        {
          name: 'gemini-api-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/gemini-api-key'
          identity: managedIdentity.id
        }
        {
          name: 'mistral-api-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/mistral-api-key'
          identity: managedIdentity.id
        }
      ]
      ingress: {
        external: true
        targetPort: 3000
        allowInsecure: false
        transport: 'auto'
      }
    }

    // ── Container template ────────────────────────────────────────────────────
    template: {
      containers: [
        {
          name: 'ai-router'
          image: containerImage
          env: [
            { name: 'PORT',             value: '3000' }
            { name: 'NODE_ENV',         value: 'production' }
            { name: 'KEY_VAULT_NAME',   value: keyVaultName }
            { name: 'ANTHROPIC_API_KEY', secretRef: 'anthropic-api-key' }
            { name: 'OPENAI_API_KEY',    secretRef: 'openai-api-key' }
            { name: 'GEMINI_API_KEY',    secretRef: 'gemini-api-key' }
            { name: 'MISTRAL_API_KEY',   secretRef: 'mistral-api-key' }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: 3000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: 3000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              timeoutSeconds: 3
              failureThreshold: 3
            }
          ]
        }
      ]
      // ── Scale: min 0, max 1 (free tier — scales to zero when idle) ──────────
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output containerAppUrl  string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output containerAppName string = containerApp.name
