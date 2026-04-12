# Azure Data & Compute FinOps Architecture

This Bicep template provisions the "12-Month Free" tier compute and data resources, heavily tagged and optimized for zero-to-low cost after the 12-month period expires.

**WARNING ON DATA WAREHOUSES (SYNAPSE):** 
Azure Synapse Analytics (Data Warehouse) starts at ~,000/month. It does NOT have a free tier. We are strictly using Azure SQL Serverless and Azure Database for PostgreSQL Flexible Server, which DO have 12-month free tiers.

``bicep
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param adminUsername string = 'familyadmin'
@secure()
param adminPassword string

var tags = {
  Environment: 'Development'
  Project: 'FamilyOS'
  BillingTier: '12-Month-Free'
  AutoDestroy: 'ReviewAt11Months'
}

// ──────────────────────────────────────────────────────────────────────────
// 1. Virtual Machine (Standard_B1s) - 750 Hours Free/Month for 12 Months
// Cost after 12 months: ~.80/month
// Use Case: Lightweight reverse proxy, Tailscale exit node, basic Docker host
// ──────────────────────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'familyos-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource publicIP 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'familyos-vm-pip'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    publicIPAllocationMethod: 'Dynamic'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'familyos-vm-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: publicIP.id }
        }
      }
    ]
  }
}

resource freeVM 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'familyos-b1s-vm'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s' // 750 hrs free/mo (12 mos)
    }
    osProfile: {
      computerName: 'familyos-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' } // 64GB free/mo
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// 2. PostgreSQL Flexible Server (Burstable) - 750 Hours Free/Month for 12 Months
// Cost after 12 months: ~.00/month (if left running 24/7)
// Use Case: pgvector for RAG/Agent Memory, Relational backend for n8n/Supabase migration
// ──────────────────────────────────────────────────────────────────────────
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01-preview' = {
  name: 'familyos-pg-free'
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms' // 750 hrs free/mo
    tier: 'Burstable'
  }
  properties: {
    version: '14'
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: 32 // 32GB free/mo
    }
  }
}

// Allow external IPs to access Postgres (Lock this down later to Cloudflare/n8n IPs)
resource pgFirewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2022-12-01-preview' = {
  parent: postgresServer
  name: 'AllowAll'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

// ──────────────────────────────────────────────────────────────────────────
// 3. Azure SQL Database (Serverless) - 100,000 vCore Seconds Free/Month
// Cost after 12 months:  to /month depending on usage (Auto-pauses)
// Use Case: Complex relational models, direct PowerBI queries
// ──────────────────────────────────────────────────────────────────────────
resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: 'familyos-sql-srv'
  location: location
  tags: tags
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlServer
  name: 'familyos-db'
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5_1' // General Purpose Serverless, 1 vCore
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    autoPauseDelay: 60 // Pauses after 1 hour of inactivity = zero compute cost!
    minCapacity: json('0.5')
  }
}
``
