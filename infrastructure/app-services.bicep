targetScope = 'resourceGroup'

param location string = resourceGroup().location
param pythonAppName string = 'python-api-free'
param nodeAppName string = 'node-api-free'

// App Service Plan (F1 - Free, Linux)
resource freeAppServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: 'free-linux-asp'
  location: location
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  properties: {
    reserved: true // Required for Linux
  }
}

// Python App Service
resource pythonApp 'Microsoft.Web/sites@2022-09-01' = {
  name: pythonAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: freeAppServicePlan.id
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12' // 3.13/3.14 rolling out, 3.12 is current safe LTS
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'DATABASE_URL', value: '@Microsoft.KeyVault(SecretUri=...)' } // Placeholder for SQL
        { name: 'COSMOS_DB_CONN', value: '@Microsoft.KeyVault(SecretUri=...)' } // Placeholder for Cosmos
      ]
    }
  }
}

// Node App Service
resource nodeApp 'Microsoft.Web/sites@2022-09-01' = {
  name: nodeAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: freeAppServicePlan.id
    siteConfig: {
      linuxFxVersion: 'NODE|22-lts' // Node 24 LTS will be available late 2025
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
      ]
    }
  }
}
