// =============================================================================
// data-and-compute.bicep — VM + PostgreSQL + SQL (12-month free tiers)
//
// ⚠️  REVIEW BEFORE DEPLOY — this template spins up compute resources.
//     All services are tagged AutoDestroy: ReviewAt11Months.
//
// Security fixes vs previous version:
//   • PostgreSQL firewall: was 0.0.0.0–255.255.255.255 (open to internet)
//                          now: Azure services only + your specific IP
//   • VM: added system-assigned managed identity (SSH key preferred — see note)
//   • All passwords remain @secure() — never logged in plaintext
//
// Requires: managed-identities.bicep deployed first.
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file data-and-compute.bicep \
//     --parameters adminPassword=<secure> allowedClientIp=<your-public-ip>
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param adminUsername string = 'willbrackenadmin'

@description('VM size — override if Standard_B1s is not available in your region. Checked sizes: Standard_B1s, Standard_B1ms, Standard_B2s, Standard_A1_v2')
param vmSize string = 'Standard_B1s'

@description('Location for Azure SQL Server AND PostgreSQL — defaults to centralus. East US/East US 2 frequently reject new server creation. Tested working: centralus, westus3.')
param sqlLocation string = 'centralus'

@description('Optional suffix override for resource names — use when ARM has a ghost reservation on the auto-generated name. Default: first 6 chars of uniqueString(resourceGroup().id).')
param nameSuffix string = take(uniqueString(resourceGroup().id), 6)

@secure()
param adminPassword string

@description('Your public IP address — only this IP can reach PostgreSQL directly. Use az rest to find: curl ifconfig.me')
param allowedClientIp string

@description('Object ID of the Entra user to set as SQL + PostgreSQL admin. Run: az ad signed-in-user show --query id -o tsv')
param adminEntraObjectId string = 'b4cf1f2a-1f1c-455b-964f-b0dc8dcd9d81'

@description('UPN or email of the Entra admin — for SQL Server must be the guest UPN in this tenant. PostgreSQL Entra admin is set post-deploy.')
param adminEntraLogin string = 'william.i.bracken_outlook.com#EXT#@willbracken.com'

var tags = {
  Environment: 'Development'
  Project: 'WillBracken'
  BillingTier: '12-Month-Free'
  AutoDestroy: 'ReviewAt11Months'
}

// ── VNet ──────────────────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'willbracken-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
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
  name: 'willbracken-vm-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'willbracken-vm-nic'
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

// ── Virtual Machine ───────────────────────────────────────────────────────────
// Default: Standard_B1s (12-month free). Override vmSize param if unavailable in region.
// System-assigned identity allows the VM to authenticate to Azure services
// (Key Vault, Storage, etc.) without storing credentials on disk.
//
// NOTE: For production use, replace adminPassword with SSH key auth:
//   osProfile.linuxConfiguration.ssh.publicKeys instead of adminPassword
resource freeVM 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'willbracken-vm'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'    // VM can now call Key Vault / Storage without stored creds
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'willbracken-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false    // Set to true and use SSH keys for better security
        // To use SSH key instead:
        // disablePasswordAuthentication: true
        // ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: '<your-pub-key>' }] }
      }
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
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

// ── PostgreSQL Flexible Server ────────────────────────────────────────────────
// Burstable B1ms — free for 12 months. PostgreSQL 16 (LTS).
// Firewall: restricted to Azure services + your IP only.
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: 'willbracken-pg-${nameSuffix}'
  location: sqlLocation    // centralus — eastus2 quota restricted for PostgreSQL
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'    // Latest LTS — upgraded from 14
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'    // Keep costs at zero
    }
    highAvailability: {
      mode: 'Disabled'    // Required for free tier
    }
    // Entra (AAD) auth: add this to enable Microsoft Entra login in addition to password
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'           // Keep enabled until you set up Entra users
    }
  }
}

// ── PostgreSQL Entra Admin ─────────────────────────────────────────────────────
// NOTE: Moved out of Bicep — Azure requires a delay after server creation before
// AAD auth operations are available. Set manually after deployment:
//
//   az postgres flexible-server ad-admin create \
//     -g willbracken-free-rg -s <server-name> \
//     --display-name "Will Bracken" \
//     --object-id b4cf1f2a-1f1c-455b-964f-b0dc8dcd9d81 \
//     --tenant-id $(az account show --query tenantId -o tsv)

// Allow Azure services to reach PostgreSQL (e.g. App Services, Functions, Container Apps)
resource pgFirewallAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'    // 0.0.0.0–0.0.0.0 = Azure-internal traffic only
    endIpAddress: '0.0.0.0'
  }
}

// Allow only your specific client IP — not the entire internet
resource pgFirewallClientIp 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: postgresServer
  name: 'AllowClientIP'
  properties: {
    startIpAddress: allowedClientIp
    endIpAddress: allowedClientIp
  }
}

// ── Azure SQL Server ──────────────────────────────────────────────────────────
// Microsoft Entra admin: enables AAD login — no SQL password needed for app accounts.
// Password auth kept for emergency DBA access.
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: 'willbracken-sql-${nameSuffix}'
  location: sqlLocation    // eastus by default — East US 2 rejects new SQL server creation
  tags: tags
  identity: {
    type: 'SystemAssigned'    // Required for Entra-only auth (Microsoft recommendation)
  }
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    // Entra-only mode: set to true after confirming managed identity can connect
    // restrictOutboundNetworkAccess: 'Disabled'
  }
}

// ── SQL Server Entra Admin ─────────────────────────────────────────────────────
// Assigns the signed-in Microsoft account as the Entra admin for SQL Server.
// This enables password-free login via DefaultAzureCredential from app services.
resource sqlEntraAdmin 'Microsoft.Sql/servers/administrators@2023-05-01-preview' = {
  parent: sqlServer
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: adminEntraLogin
    sid: adminEntraObjectId
    tenantId: subscription().tenantId
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlServer
  name: 'willbracken-db'
  location: sqlLocation
  tags: tags
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause'
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output vmPrincipalId string = freeVM.identity.principalId
output vmName string = freeVM.name
output vmSize string = vmSize
output postgresServerFqdn string = postgresServer.properties.fullyQualifiedDomainName
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlServerName string = sqlServer.name
