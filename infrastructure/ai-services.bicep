targetScope = 'resourceGroup'
param location string = resourceGroup().location

resource languageService 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: 'familyos-lang-${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'F0'
  }
  kind: 'TextAnalytics'
  properties: {
    customSubDomainName: 'familyos-lang-${uniqueString(resourceGroup().id)}'
  }
}

// User Assigned Identity for the Bot Service
resource botIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'familyos-bot-msi'
  location: location
}

// Free Azure Bot Service (Updated to UserAssignedMSI)
resource botService 'Microsoft.BotService/botServices@2023-09-15-preview' = {
  name: 'familyos-bot'
  location: 'global'
  sku: {
    name: 'F0' 
  }
  properties: {
    displayName: 'FamilyOS Assistant'
    // NOTE: Update endpoint after Function App is deployed — use actual azurewebsites.net URL
    // or n8n.willbracken.com/webhook/... if routing through n8n instead
    endpoint: 'https://placeholder-update-after-deploy.azurewebsites.net/api/messages'
    msaAppId: botIdentity.properties.clientId
    msaAppMSIResourceId: botIdentity.id          // Required for UserAssignedMSI — links identity to app
    msaAppType: 'UserAssignedMSI'                // Fixed: MultiTenant is deprecated per March 2024 API change
    msaAppTenantId: subscription().tenantId
  }
}

resource mlWorkspace 'Microsoft.MachineLearningServices/workspaces@2023-04-01' = {
  name: 'familyos-ml-${uniqueString(resourceGroup().id)}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    friendlyName: 'FamilyOS Data Science'
  }
}
