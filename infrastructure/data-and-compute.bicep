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
      vmSize: 'Standard_B1s'
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
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01-preview' = {
  name: 'familyos-pg-free-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '14'
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: 32
    }
  }
}

resource pgFirewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2022-12-01-preview' = {
  parent: postgresServer
  name: 'AllowAll'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: 'familyos-sql-srv-${uniqueString(resourceGroup().id)}'
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
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    useFreeLimit: true                              // REQUIRED — activates SQL free tier (32GB, 100K vCore-s/mo)
    freeLimitExhaustionBehavior: 'AutoPause'        // Pause instead of billing on overage (safe)
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
  }
}
