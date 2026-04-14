// =============================================================================
// azure-openai.bicep — Azure OpenAI account + model deployments
// Resource group: willbracken-free-rg
//
// Deploys:
//   • Azure OpenAI account (kind: OpenAI, sku: S0, API version 2023-10-01-preview)
//   • gpt-4o deployment              (capacity: 10 TPM, sku: Standard)
//   • gpt-4o-mini deployment         (capacity: 20 TPM, sku: Standard)
//   • text-embedding-3-small         (capacity: 50 TPM, sku: Standard)
//   • Outputs: endpoint, accountName, resourceId
//
// ⚠️  REVIEW BEFORE DEPLOY — Azure OpenAI S0 has no free-tier billing cap.
//     Monitor usage in Azure Cost Management and set budget alerts.
//     All deployments are serial (Azure requirement for the same account).
//
// Prerequisites:
//   • Azure OpenAI approved for this subscription/region.
//     Request access at https://aka.ms/oai/access if needed.
//   • Subscription: 11301eb9-a26b-4b41-badb-c1b10f446d99
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file azure-openai.bicep
//
// Outputs: endpoint, accountName, resourceId
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region for the OpenAI account. Must be a region where Azure OpenAI is available.')
param location string = 'eastus'

@description('Optional suffix override — defaults to first 6 chars of uniqueString(resourceGroup().id). Override when ARM has a ghost reservation.')
param nameSuffix string = take(uniqueString(resourceGroup().id), 6)

@description('GPT-4o deployment capacity in thousands of tokens per minute.')
@minValue(1)
@maxValue(450)
param gpt4oCapacity int = 10

@description('GPT-4o-mini deployment capacity in thousands of tokens per minute.')
@minValue(1)
@maxValue(2000)
param gpt4oMiniCapacity int = 20

@description('text-embedding-3-small deployment capacity in thousands of tokens per minute.')
@minValue(1)
@maxValue(350)
param embeddingCapacity int = 50

var accountName = 'willbracken-aoai-${nameSuffix}'

var tags = {
  Environment:  'Development'
  Project:      'WillBracken'
  BillingTier:  '12-Month-Free'
  AutoDestroy:  'ReviewAt11Months'
}

// ── Azure OpenAI Account ──────────────────────────────────────────────────────
resource openAIAccount 'Microsoft.CognitiveServices/accounts@2023-10-01-preview' = {
  name: accountName
  location: location
  kind: 'OpenAI'
  tags: tags
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: accountName    // Must be globally unique — derived from resource name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false             // Set true once all callers use DefaultAzureCredential
    networkAcls: {
      defaultAction: 'Allow'           // Tighten to 'Deny' with VNet rules when VNet exists
    }
    restore: false
  }
}

// ── GPT-4o Deployment ─────────────────────────────────────────────────────────
// Model deployments within the same account must be created serially.
resource gpt4oDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-10-01-preview' = {
  parent: openAIAccount
  name: 'gpt-4o'
  sku: {
    name: 'Standard'
    capacity: gpt4oCapacity
  }
  properties: {
    model: {
      format:  'OpenAI'
      name:    'gpt-4o'
      version: '2024-11-20'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.Default'
  }
}

// ── GPT-4o-mini Deployment ────────────────────────────────────────────────────
// Higher default capacity — suitable for classification, extraction, summarisation.
resource gpt4oMiniDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-10-01-preview' = {
  parent: openAIAccount
  name: 'gpt-4o-mini'
  dependsOn: [gpt4oDeployment]    // Serial deployment required within the same account
  sku: {
    name: 'Standard'
    capacity: gpt4oMiniCapacity
  }
  properties: {
    model: {
      format:  'OpenAI'
      name:    'gpt-4o-mini'
      version: '2024-07-18'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.Default'
  }
}

// ── text-embedding-3-small Deployment ────────────────────────────────────────
// Used for vector search / RAG pipelines. High TPM ceiling keeps costs low.
resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-10-01-preview' = {
  parent: openAIAccount
  name: 'text-embedding-3-small'
  dependsOn: [gpt4oMiniDeployment]    // Serial deployment required within the same account
  sku: {
    name: 'Standard'
    capacity: embeddingCapacity
  }
  properties: {
    model: {
      format:  'OpenAI'
      name:    'text-embedding-3-small'
      version: '1'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.Default'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Azure OpenAI HTTPS endpoint — set as AZURE_OPENAI_ENDPOINT in app config')
output endpoint string = openAIAccount.properties.endpoint

@description('Azure OpenAI account name')
output accountName string = openAIAccount.name

@description('Full resource ID of the Azure OpenAI account')
output resourceId string = openAIAccount.id

@description('GPT-4o deployment name — pass as deploymentName to openai SDK')
output gpt4oDeploymentName string = gpt4oDeployment.name

@description('GPT-4o-mini deployment name')
output gpt4oMiniDeploymentName string = gpt4oMiniDeployment.name

@description('text-embedding-3-small deployment name')
output embeddingDeploymentName string = embeddingDeployment.name
