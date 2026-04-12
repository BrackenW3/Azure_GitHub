param location string = resourceGroup().location
param prefix string = '12mofree${uniqueString(resourceGroup().id)}'

@description('The administrator password for the SQL server.')
@secure()
param sqlAdminPassword string

// 1. Storage Account (Standard_LRS for Blob Storage)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: toLower(substring(replace('${prefix}blob', '-', ''), 0, min(24, length(replace('${prefix}blob', '-', '')))))
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
  }
}

// 2. Azure SQL Server
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: '${prefix}-sql-srv'
  location: location
  properties: {
    administratorLogin: 'sqladmin'
    administratorLoginPassword: sqlAdminPassword
  }
}

// 3. Azure SQL Database (Serverless with Auto-pause)
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlServer
  name: '${prefix}-db'
  location: location
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1 // Max vCores
  }
  properties: {
    useFreeLimit: true                              // REQUIRED — activates SQL free tier (32GB, 100K vCore-s/mo)
    freeLimitExhaustionBehavior: 'AutoPause'        // Pause instead of billing on overage (safe)
    autoPauseDelay: 60                              // Pauses compute after 60 minutes of inactivity
    minCapacity: json('0.5')                        // Minimum vCores before pause
    requestedBackupStorageRedundancy: 'Local'       // Cheapest redundancy tier
  }
}
