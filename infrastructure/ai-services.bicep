// =============================================================================
// ai-services.bicep — AI/ML services (free tiers)
//
// Language Service (TextAnalytics F0), Bot Service (F0), ML Workspace (Basic).
// ML Workspace uses SystemAssigned identity with RBAC on its storage account.
// Bot Service uses its own dedicated identity (Azure requirement).
//
// Requires: managed-identities.bicep deployed first.
//           always-free.bicep deployed first (storage account output needed).
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file ai-services.bicep \
//     --parameters storageAccountName=<from always-free output> \
//                  keyVaultName=<from always-free-extended output>
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param baseName string = 'willbracken'

@description('Storage account name from always-free.bicep output — ML Workspace needs it for datasets')
param storageAccountName string

@description('Key Vault name from always-free-extended.bicep output')
param keyVaultName string

@description('Set false if a free TextAnalytics account already exists in this subscription (limit: 1 per subscription)')
param deployLanguageService bool = true

@description('Set false to skip Bot Service — requires separate MSA App registration setup')
param deployBotService bool = true

@description('Set false to skip ML Workspace — deploys App Insights + ML together')
param deployMlWorkspace bool = true

// Built-in role IDs
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleKeyVaultSecretsUser        = '4633458b-17de-408a-b874-0445c86b69e6'

// Reference existing resources for RBAC scoping
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Reference bot identity created in managed-identities.bicep
resource botIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: '${baseName}-bot-id'
}

// ── Language Service (TextAnalytics F0) ───────────────────────────────────────
// Free: 5K transactions/month for sentiment, key phrases, entity recognition.
// Used by n8n workflows to classify incoming emails and extract tasks.
// Limit: 1 free account per subscription. Set deployLanguageService=false if one already exists.
resource languageService 'Microsoft.CognitiveServices/accounts@2023-05-01' = if (deployLanguageService) {
  name: '${baseName}-lang-${take(uniqueString(resourceGroup().id), 6)}'
  location: location
  sku: {
    name: 'F0'
  }
  kind: 'TextAnalytics'
  identity: {
    type: 'SystemAssigned'    // Cognitive Services supports system identity for CMK
  }
  properties: {
    customSubDomainName: '${baseName}-lang-${take(uniqueString(resourceGroup().id), 6)}'
    publicNetworkAccess: 'Enabled'
    // disableLocalAuth: true  ← enable after confirming API key access is not needed
  }
}

// ── Bot Service ───────────────────────────────────────────────────────────────
// Free F0: 10K premium messages/month, unlimited standard messages.
// Uses dedicated bot identity (not the shared platform identity — Azure requirement).
// deployBotService=false by default until you set up the messaging endpoint.
// Setup: deploy your Function App or n8n webhook first, then enable this.
resource botService 'Microsoft.BotService/botServices@2023-09-15-preview' = if (deployBotService) {
  name: '${baseName}-bot'
  location: 'global'
  sku: {
    name: 'F0'
  }
  properties: {
    displayName: 'Family Assistant'
    endpoint: 'https://placeholder-update-after-deploy.azurewebsites.net/api/messages'
    msaAppId: botIdentity.properties.clientId
    msaAppMSIResourceId: botIdentity.id
    msaAppType: 'UserAssignedMSI'
    msaAppTenantId: subscription().tenantId
    // Note: Bot Framework registration also requires MSA app setup in portal
    // after deployment. See: https://aka.ms/bot-msa-app
  }
}

// ── Application Insights (required by ML Workspace) ───────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (deployMlWorkspace) {
  name: '${baseName}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ── Log Analytics Workspace for App Insights ──────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = if (deployMlWorkspace) {
  name: 'willbracken-logs-${take(uniqueString(resourceGroup().id), 6)}'
}

// ── ML Workspace ──────────────────────────────────────────────────────────────
// Free Basic tier — for model training, dataset management, experiment tracking.
// SystemAssigned identity is standard for ML Workspace (easier to manage).
// RBAC on storage account is required for reading/writing ML datasets.
// Requires: App Insights (deployed above) + Storage + Key Vault.
resource mlWorkspace 'Microsoft.MachineLearningServices/workspaces@2023-04-01' = if (deployMlWorkspace) {
  name: '${baseName}-ml-${take(uniqueString(resourceGroup().id), 6)}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    friendlyName: 'WillBracken Data Science'
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: deployMlWorkspace ? any(appInsights).id : null
    publicNetworkAccess: 'Enabled'
  }
}

// ── RBAC: ML Workspace → Storage Account ──────────────────────────────────────
resource mlStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployMlWorkspace) {
  name: guid(storageAccount.id, 'mlworkspace', roleStorageBlobDataContributor)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: deployMlWorkspace ? any(mlWorkspace).identity.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

// ── RBAC: ML Workspace → Key Vault ────────────────────────────────────────────
resource mlKvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployMlWorkspace) {
  name: guid(keyVault.id, 'mlworkspace', roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: deployMlWorkspace ? any(mlWorkspace).identity.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output languageServiceEndpoint string = deployLanguageService ? any(languageService).properties.endpoint : 'existing-in-familyos-rg (free-language-service)'
output languageServicePrincipalId string = deployLanguageService ? any(languageService).identity.principalId : 'not-deployed'
output mlWorkspaceName string = deployMlWorkspace ? any(mlWorkspace).name : 'not-deployed'
output mlWorkspacePrincipalId string = deployMlWorkspace ? any(mlWorkspace).identity.principalId : 'not-deployed'
output botServiceName string = deployBotService ? any(botService).name : 'not-deployed'
output botIdentityClientId string = botIdentity.properties.clientId
