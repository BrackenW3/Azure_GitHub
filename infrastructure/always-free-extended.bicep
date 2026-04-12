// =============================================================================
// always-free-extended.bicep — Second layer of Azure always-free services
//
// These services have NO expiry — they're free forever regardless of subscription age.
// Deploy alongside always-free.bicep (Cosmos DB + Functions already there).
//
// Provisions:
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
//     --resource-group willbracken-rg \
//     --template-file always-free-extended.bicep
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Short base name used for all resource names')
param baseName string = 'willbracken'

@description('Publisher email for API Management (required)')
param apimPublisherEmail string = 'will@willbracken.com'

@description('Publisher name for API Management')
param apimPublisherName string = 'Will Bracken'

var uniqueSuffix = take(uniqueString(resourceGroup().id), 6)

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
      name: 'standard'       // Standard is free within 10K ops/month
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true    // Use RBAC instead of access policies (modern pattern)
    enableSoftDelete: true           // 90-day recovery window (on by default)
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'   // Required for MCP + n8n access without VNet
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// ── Container Apps Environment ────────────────────────────────────────────────
// Serverless container hosting. No VM quota needed. Scale to zero = free.
// Free: 180K vCPU-seconds + 360K GiB-seconds per subscription per month.
// This environment hosts any Docker container without managing Kubernetes.
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${baseName}-logs-${uniqueSuffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30    // Minimum retention — 5GB/month free
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2023-11-02-preview' = {
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
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'  // Always-free consumption profile
      }
    ]
  }
}

// Placeholder Container App — replace image with your actual workloads.
// Example use cases: email classifier worker, Neo4j sync job, webhook handler.
// Scale to 0 replicas when not in use = $0 cost.
resource placeholderApp 'Microsoft.App/containerApps@2023-11-02-preview' = {
  name: '${baseName}-app'
  location: location
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    workloadProfileName: 'Consumption'
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
            cpu: json('0.25')    // Quarter vCPU — cheapest option
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0           // Scale to zero = $0 when idle
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
// Auto-deploys from GitHub via GitHub Actions. Custom domains supported.
// Perfect for: Platform Home frontend, family task submission form.
resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: '${baseName}-web'
  location: location   // Static Web Apps have limited region availability — eastus2, westus2, centralus, etc.
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    buildProperties: {
      skipGithubActionWorkflowGeneration: true   // We'll manage GitHub Actions ourselves
    }
  }
}

// ── API Management (Consumption tier) ────────────────────────────────────────
// API gateway for all services. 1M calls/month free on Consumption tier.
// Route external requests → n8n webhooks / CF Workers / Azure Functions.
// Note: Consumption tier takes ~5 minutes to provision (normal).
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: '${baseName}-apim-${uniqueSuffix}'
  location: location
  sku: {
    name: 'Consumption'   // Always free for first 1M calls/month
    capacity: 0           // 0 = Consumption mode (no dedicated capacity)
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
  location: location
  properties: {
    source: resourceGroup().id
    topicType: 'Microsoft.Resources.ResourceGroups'   // Fires on resource group events
  }
}

// ── Service Bus (Basic tier) ──────────────────────────────────────────────────
// Message queuing. Free: 10M messages/month on Basic tier.
// Use for: async email processing queue, retry logic, n8n ↔ Functions decoupling.
// Note: Basic tier does NOT support Topics (only queues). Use Standard for Topics.
resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: '${baseName}-bus-${uniqueSuffix}'
  location: location
  sku: {
    name: 'Basic'     // 10M messages/month free
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
    maxSizeInMegabytes: 1024      // 1GB queue size
    defaultMessageTimeToLive: 'P7D'  // 7-day TTL
    lockDuration: 'PT5M'          // 5-minute processing lock
    maxDeliveryCount: 3           // Retry 3 times before dead-lettering
    deadLetteringOnMessageExpiration: true
  }
}

// ── AI Search (Free F0 tier) ──────────────────────────────────────────────────
// Cognitive search for structured data. Free F0: 3 indexes, 50MB, 3 indexers.
// Enough for email metadata search + Jira ticket search (2 indexes).
// Compare quality vs Cloudflare Vectorize — keep winner, drop loser.
// If F0 wins the quality test: upgrade to S1 only if needed (~$73/month).
resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' = {
  name: '${baseName}-search-${uniqueSuffix}'
  location: location
  sku: {
    name: 'free'     // F0 — always free, no expiry. 3 indexes, 50MB.
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

// ── App Configuration ─────────────────────────────────────────────────────────
// Feature flags and app settings — centralized config store.
// Free: 10M requests/month. Store n8n webhook URLs, feature toggles, env-specific settings.
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2023-03-01' = {
  name: '${baseName}-config-${uniqueSuffix}'
  location: location
  sku: {
    name: 'free'   // 10M requests/month, 1MB storage — always free
  }
  properties: {
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultName string = keyVault.name
output containerAppsEnvId string = containerAppsEnv.id
output containerAppUrl string = 'https://${placeholderApp.properties.configuration.ingress.fqdn}'
output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
output apimGatewayUrl string = 'https://${apim.properties.gatewayUrl}'
output serviceBusConnectionString string = listKeys('${serviceBusNamespace.id}/AuthorizationRules/RootManageSharedAccessKey', serviceBusNamespace.apiVersion).primaryConnectionString
output aiSearchEndpoint string = 'https://${aiSearch.name}.search.windows.net'
output appConfigEndpoint string = appConfig.properties.endpoint
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.properties.customerId
