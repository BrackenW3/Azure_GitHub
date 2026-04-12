param location string = resourceGroup().location
param prefix string = 'burn30day${uniqueString(resourceGroup().id)}'

@description('The administrator password for the VM.')
@secure()
param adminPassword string

// 1. Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
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

// 2. Network Interface
resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: '${prefix}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

// 3. Spot Virtual Machine (Ubuntu)
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: '${prefix}-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D4s_v3' // Compute optimized for short bursts
    }
    priority: 'Spot' // Strict spot pricing
    evictionPolicy: 'Delete' // Delete the VM AND underlying disk on eviction to stop billing
    billingProfile: {
      maxPrice: -1 // Allow payment up to the on-demand price before eviction
    }
    osProfile: {
      computerName: 'spotvm'
      adminUsername: 'azureuser'
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
        managedDisk: {
          storageAccountType: 'Standard_LRS' // Lowest cost disk for short term
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}
