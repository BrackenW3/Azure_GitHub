// =============================================================================
// always-free-extended.bicep — Second layer of Azure always-free services
//
// These services have NO expiry — they're free forever regardless of subscription age.
// Deploy alongside always-free.bicep (Cosmos DB + Functions already there).
//
// Provisions:
//   • User-assigned Managed Identity (shared auth identity for all services)
//   • RBAC role assignments (Key Vault Secrets User, App Config Reader, SB Data Receiver)
//   • Key Vault (secrets management — 10K ops/month free)
//   • Container Apps Environment + placeholder app (180K vCPU-s/month free)
//   • Static Web Apps (free tier — unlimited sites, 100GB/month)
//   • API Management Consumption (1M calls/month free gateway)
//   • Event Grid System Topic (100K ops/month free)
//   • Service Bus Basic namespace (10M messages/month free)
//   • AI Search Free tier (3 indexes, 50MB — F0)
//   • App Configuration (10M ops/month free)
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file always-free-extended.bicep
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Short base name used for all resource names')
param baseName string = 'willbracken'

@description('Publisher email for API Management (required)')
param apimPublisherEmail string = 'william.i.bracken@outlook.com'

@description('Publisher name for API Management')
param apimPublisherName string = 'Will Bracken'

@description('Location for Static Web Apps — limited region support, must be eastus2/westus2/centralus/westeurope/eastasia')
param staticWebAppLocation string = 'eastus2'

var uniqueSuffix = take(uniqueString(resourceGroup().id), 6)

// ── Built-in RBAC role definition IDs ────────────────────────────────────────
var roleKeyVaultSecretsUser     = '4633458b-17de-408a-b874-0445c86b69e6'
var roleAppConfigDataReader     = '516239f1-63e1-4d78-a4de-a74fb236a071'
var roleServiceBusDataReceiver  = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
var roleServiceBusDataSender    = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'

// ── Platform Managed Identity (reference — created by managed-identities.bicep) ──
// Do not recreate here. managed-identities.bicep is the authoritative source.
// Deploy managed-identities.bicep first, then pass its output as platformIdentityId.
param platformIdentityId string = ''

var resolvedIdentityName = !empty(platformIdentityId)
  ? last(split(platformIdentityId, '/'))
  : '${baseName}-platform-id'

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: resolvedIdentityName
}

// ── Key Vault ─────────────────────────────────────────────────────────────────
// Secrets manager: store all API keys, connection strings, SP credentials here.
// Free tier: 10K operations/month. Soft-delete enabled by default (90-day retention).
// Claude MCP server can read secrets directly via azure://keyvault/ resource.
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${baseName}-kv-${uniqueSuffix}'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true    // RBAC — managed identity is granted access below
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// Grant managed identity read access to Key Vault secrets.
// Eliminates the need for connection-string-based secret retrieval.
resource kvSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentity.id, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Log Analytics Workspace ───────────────────────────────────────────────────
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${baseName}-logs-${uniqueSuffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ── Container Apps Environment ────────────────────────────────────────────────
// Serverless container hosting. No VM quota needed. Scale to zero = free.
// Free: 180K vCPU-seconds + 360K GiB-seconds per subscription per month.
resource containerAppsEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${baseName}-cae'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

// Container App — uses managed identity so it can pull secrets from Key Vault
// without any hardcoded credentials.  Replace the placeholder image with your
// actual workload image.  Scale to 0 replicas = $0 when idle.
resource placeholderApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${baseName}-app'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        allowInsecure: false
      }
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'placeholder'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              // App reads its own managed identity client ID at runtime
              name: 'AZURE_CLIENT_ID'
              value: managedIdentity.properties.clientId
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// ── Static Web Apps (Free tier) ───────────────────────────────────────────────
// Host any static frontend (React, Vue, Next.js, plain HTML).
// Free: unlimited sites, 100GB bandwidth/month, 500 deploys/month.
resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: '${baseName}-web'
  location: staticWebAppLocation
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
  }
}

// ── API Management (Consumption tier) ────────────────────────────────────────
// API gateway for all services. 1M calls/month free on Consumption tier.
// Note: Consumption tier takes ~5 minutes to provision (normal).
resource apim 'Microsoft.ApiManagement/service@2022-08-01' = {
  name: '${baseName}-apim-${uniqueSuffix}'
  location: location
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
    }
  }
}

// ── Event Grid System Topic ───────────────────────────────────────────────────
// Event routing: fire-and-forget events between Azure services.
// Free: first 100K operations/month.
// Use for: new email arrived → trigger Functions → trigger n8n webhook.
resource eventGridTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = {
  name: '${baseName}-events'
  location: 'global'    // ResourceGroups topic type requires 'global' — not the RG location
  properties: {
    source: resourceGroup().id
    topicType: 'Microsoft.Resources.ResourceGroups'
  }
}

// ── Service Bus (Basic tier) ──────────────────────────────────────────────────
// Message queuing. Free: 10M messages/month on Basic tier.
// Note: Basic tier does NOT support Topics (only queues). Upgrade to Standard for Topics.
resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: '${baseName}-bus-${uniqueSuffix}'
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

// Email processing queue — async pipeline decoupling
resource emailQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: 'email-processing'
  properties: {
    maxSizeInMegabytes: 1024
    defaultMessageTimeToLive: 'P7D'
    lockDuration: 'PT5M'
    maxDeliveryCount: 3
    deadLetteringOnMessageExpiration: true
  }
}

// Grant managed identity send + receive on Service Bus.
// n8n and Container App workers authenticate via identity — no SAS keys needed.
resource sbReceiverAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, managedIdentity.id, roleServiceBusDataReceiver)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleServiceBusDataReceiver)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource sbSenderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBusNamespace.id, managedIdentity.id, roleServiceBusDataSender)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleServiceBusDataSender)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── AI Search ─────────────────────────────────────────────────────────────────
// SKIPPED: Free tier (F0) is limited to 1 per subscription and one already exists.
// Find existing service: portal → Search services → willbracken-search-*

// ── App Configuration ─────────────────────────────────────────────────────────
// Feature flags and app settings — centralized config store.
// Free: 10M requests/month. Store n8n webhook URLs, feature toggles, env settings.
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2023-03-01' = {
  name: '${baseName}-config-${uniqueSuffix}'
  location: location
  sku: {
    name: 'free'
  }
  properties: {
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

// Grant managed identity read access to App Configuration.
resource appConfigReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, managedIdentity.id, roleAppConfigDataReader)
  scope: appConfig
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAppConfigDataReader)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Store Service Bus connection string in Key Vault ──────────────────────────
// Workloads that still need a connection string (e.g. older clients) can read
// it from Key Vault using the managed identity — no secret in code or config.
resource sbConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'servicebus-connection-string'
  properties: {
    value: listKeys('${serviceBusNamespace.id}/AuthorizationRules/RootManageSharedAccessKey', '2021-11-01').primaryConnectionString
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output managedIdentityClientId string = managedIdentity.properties.clientId
output managedIdentityResourceId string = managedIdentity.id
output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultName string = keyVault.name
output containerAppsEnvId string = containerAppsEnv.id
output containerAppUrl string = placeholderApp.properties.configuration.ingress != null
  ? 'https://${placeholderApp.properties.configuration.ingress.fqdn}'
  : 'ingress not yet assigned — check portal'
output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
output apimGatewayUrl string = apim.properties.gatewayUrl
output serviceBusNamespace string = serviceBusNamespace.name
output serviceBusConnectionStringSecretUri string = sbConnectionStringSecret.properties.secretUri
output appConfigEndpoint string = appConfig.properties.endpoint
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.properties.customerId
