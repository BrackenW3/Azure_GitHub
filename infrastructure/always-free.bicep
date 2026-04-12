param location string = resourceGroup().location
param prefix string = 'alwaysfree${uniqueString(resourceGroup().id)}'

// 1. Cosmos DB (Free Tier - Limit 1 per subscription)
resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: '${prefix}-cosmos'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: true // Strictly enforce Free Tier
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
  }
}

// 2. App Service Plan (F1 Free Tier)
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-asp'
  location: location
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  kind: 'linux'
  properties: {
    reserved: true // Required for Linux
  }
}

// 3. Storage Account (Required for Function App state)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: toLower(substring(replace('${prefix}sa', '-', ''), 0, min(24, length(replace('${prefix}sa', '-', '')))))
  location: location
  sku: {
    name: 'Standard_LRS' // Lowest cost standard storage
  }
  kind: 'StorageV2'
}

// 4. Function App Consumption Plan
resource consumptionPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-consumption'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true // Required for Linux
  }
}

// 5. Function App (Python 3.11, Consumption Plan)
resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${prefix}-func'
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: consumptionPlan.id
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
      ]
    }
  }
}
