# =============================================================================
# fix-azure-permissions.ps1
# Audits and fixes Azure Entra ID tenant permissions for willbracken.com
#
# Fixes:
#   1. Removes root-scope User Access Administrator elevation (security)
#   2. Creates will@willbracken.com as native Entra ID member (not guest)
#   3. Creates security@willbracken.com as native Entra ID member
#   4. Assigns Global Administrator to both native accounts
#   5. Removes #EXT# guest accounts from privileged roles
#   6. Creates service principals for Claude MCP + n8n automation
#   7. Outputs full summary report
#
# Prerequisites (run in PowerShell as Administrator):
#   Install-Module -Name Az -AllowClobber -Force
#   Install-Module -Name AzureAD -AllowClobber -Force (or use Microsoft.Graph)
#
# Usage:
#   1. Complete MANUAL STEPS below in Azure Portal first
#   2. Run: .\fix-azure-permissions.ps1
#   3. Log in as william3bracken@outlook.com when prompted (tenant owner)
# =============================================================================

#Requires -Version 5.1

param(
    [string]$TenantDomain = "willbracken.com",
    [string]$AdminEmail1  = "will@willbracken.com",
    [string]$AdminEmail2  = "security@willbracken.com",
    [switch]$DryRun       = $false,   # use -DryRun to preview without making changes
    [switch]$SkipCleanup  = $false    # use -SkipCleanup to skip removing guest roles
)

# ── Colours ───────────────────────────────────────────────────────────────────
function Write-Step  { Write-Host "`n▶  $args" -ForegroundColor Cyan }
function Write-OK    { Write-Host "   ✓ $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "   ⚠  $args" -ForegroundColor Yellow }
function Write-Error2{ Write-Host "   ✗ $args" -ForegroundColor Red }
function Write-Info  { Write-Host "   → $args" -ForegroundColor Gray }

if ($DryRun) {
    Write-Host "`n[DRY RUN MODE — no changes will be made]`n" -ForegroundColor Magenta
}

# =============================================================================
# MANUAL STEPS — Do these in Azure Portal BEFORE running this script
# =============================================================================
Write-Host @"

════════════════════════════════════════════════════════════════════
  BEFORE RUNNING THIS SCRIPT — complete these steps in the portal
════════════════════════════════════════════════════════════════════

  1. Log into portal.azure.com as: william3bracken@outlook.com
     (or whichever MSA created the Azure subscription)

  2. Remove root-scope elevation:
     a. Microsoft Entra ID → Properties
        → "Access management for Azure resources" → Toggle ON → Save
        (This temporarily gives you root scope to clean it up)

     b. Subscriptions → Access control (IAM) → Role assignments
        → Scope filter: Root (/)
        → Find: will.bracken.icloud_outlook.com#EXT# | User Access Administrator
        → Delete ✕ → Confirm

     c. Back to Entra ID → Properties
        → "Access management for Azure resources" → Toggle OFF → Save
        (Remove YOUR OWN elevation too — it's no longer needed)

  3. Press Enter here to continue with automated fixes...

════════════════════════════════════════════════════════════════════
"@ -ForegroundColor Yellow

Read-Host "Press Enter when portal steps are complete"

# =============================================================================
# Phase 0 — Login
# =============================================================================
Write-Step "Logging in to Azure..."

try {
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Connect-AzAccount -TenantDomain $TenantDomain -UseDeviceAuthentication
    } else {
        Write-OK "Already logged in as: $($context.Account.Id)"
        $confirm = Read-Host "   Use this account? [Y/n]"
        if ($confirm -eq "n") {
            Disconnect-AzAccount | Out-Null
            Connect-AzAccount -TenantDomain $TenantDomain -UseDeviceAuthentication
        }
    }
} catch {
    Write-Error2 "Login failed: $_"
    exit 1
}

$context   = Get-AzContext
$tenantId  = $context.Tenant.Id
$subId     = $context.Subscription.Id
$subName   = $context.Subscription.Name

Write-OK "Tenant:       $tenantId"
Write-OK "Subscription: $subName ($subId)"
Write-OK "Logged in as: $($context.Account.Id)"

# =============================================================================
# Phase 1 — Audit Current State
# =============================================================================
Write-Step "Auditing current role assignments..."

# All role assignments at subscription scope
$allRoles = Get-AzRoleAssignment -Scope "/subscriptions/$subId" -ErrorAction SilentlyContinue

# Flag guest (#EXT#) accounts with privileged roles
$guestAdmins = $allRoles | Where-Object {
    $_.SignInName -like "*#EXT#*" -and
    $_.RoleDefinitionName -in @("Owner","Contributor","User Access Administrator","Global Administrator")
}

Write-Info "Total role assignments at subscription scope: $($allRoles.Count)"

if ($guestAdmins.Count -gt 0) {
    Write-Warn "Guest accounts with privileged roles:"
    $guestAdmins | ForEach-Object {
        Write-Info "  $($_.SignInName) | $($_.RoleDefinitionName) | $($_.Scope)"
    }
} else {
    Write-OK "No guest accounts with privileged roles at subscription scope"
}

# Check root scope separately
try {
    $rootRoles = Get-AzRoleAssignment -Scope "/" -ErrorAction SilentlyContinue
    if ($rootRoles) {
        Write-Warn "Role assignments at ROOT scope (/) — these are DANGEROUS:"
        $rootRoles | ForEach-Object {
            Write-Warn "  $($_.SignInName) | $($_.RoleDefinitionName) | /"
        }
    } else {
        Write-OK "No role assignments at root scope (/)"
    }
} catch {
    Write-Info "Cannot read root scope (expected if elevation was removed — this is good)"
}

# =============================================================================
# Phase 2 — Verify Custom Domain
# =============================================================================
Write-Step "Checking custom domain verification for $TenantDomain..."

try {
    # Use Az REST to check domains
    $domainsResponse = Invoke-AzRestMethod -Uri "https://graph.microsoft.com/v1.0/domains" -Method GET
    $domains = ($domainsResponse.Content | ConvertFrom-Json).value

    $customDomain = $domains | Where-Object { $_.id -eq $TenantDomain }

    if ($customDomain) {
        if ($customDomain.isVerified) {
            Write-OK "Domain $TenantDomain is verified ✓"
        } else {
            Write-Warn "Domain $TenantDomain is NOT verified"
            Write-Info "Fix: Entra ID → Custom domain names → $TenantDomain → Verify"
            Write-Info "Add the TXT record shown to your Cloudflare DNS, then click Verify"
            Write-Warn "Cannot create native @willbracken.com users until domain is verified"
        }
    } else {
        Write-Warn "Domain $TenantDomain not found in tenant"
        Write-Info "Fix: Entra ID → Custom domain names → Add custom domain → $TenantDomain"
    }
} catch {
    Write-Warn "Could not check domain status: $_"
}

# =============================================================================
# Phase 3 — Create/Fix Native Admin Users
# =============================================================================
Write-Step "Creating/verifying native admin accounts..."

foreach ($email in @($AdminEmail1, $AdminEmail2)) {
    Write-Info "Processing: $email"

    try {
        # Check if user already exists
        $existingUser = Invoke-AzRestMethod `
            -Uri "https://graph.microsoft.com/v1.0/users/$email" `
            -Method GET

        $userExists = $existingUser.StatusCode -eq 200

        if ($userExists) {
            $userData = $existingUser.Content | ConvertFrom-Json
            $userType = $userData.userType

            if ($userType -eq "Guest") {
                Write-Warn "$email exists as GUEST — should be converted to Member"
                Write-Info "  To convert: Entra ID → Users → $email → Edit → User type: Member"
                Write-Info "  (This cannot be done via script — requires portal)"
            } else {
                Write-OK "$email already exists as native Member"
            }
        } else {
            # User doesn't exist — create as native member
            $displayName = if ($email -eq $AdminEmail1) { "Will Bracken" } else { "Security Admin" }
            $tempPassword = "Temp$(Get-Random -Minimum 10000 -Maximum 99999)!Az"
            $mailNickname = $email.Split("@")[0]

            $userBody = @{
                accountEnabled    = $true
                displayName       = $displayName
                mailNickname      = $mailNickname
                userPrincipalName = $email
                userType          = "Member"
                passwordProfile   = @{
                    forceChangePasswordNextSignIn = $true
                    password                      = $tempPassword
                }
            } | ConvertTo-Json

            if (-not $DryRun) {
                $createResponse = Invoke-AzRestMethod `
                    -Uri "https://graph.microsoft.com/v1.0/users" `
                    -Method POST `
                    -Payload $userBody

                if ($createResponse.StatusCode -in 200, 201) {
                    Write-OK "Created native user: $email"
                    Write-Warn "  Temp password: $tempPassword  (change on first login)"
                } else {
                    Write-Error2 "Failed to create $email`: $($createResponse.Content)"
                }
            } else {
                Write-OK "[DRY RUN] Would create native user: $email (temp pass: $tempPassword)"
            }
        }
    } catch {
        Write-Warn "Error processing $email`: $_"
    }
}

# =============================================================================
# Phase 4 — Assign Global Administrator Role
# =============================================================================
Write-Step "Assigning Global Administrator role to admin accounts..."

# Global Administrator role template ID (fixed in all tenants)
$globalAdminRoleId = "62e90394-69f5-4237-9190-012177145e10"

foreach ($email in @($AdminEmail1, $AdminEmail2)) {
    try {
        # Check if already a Global Admin
        $memberResponse = Invoke-AzRestMethod `
            -Uri "https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$globalAdminRoleId/members" `
            -Method GET

        $members = ($memberResponse.Content | ConvertFrom-Json).value
        $alreadyAdmin = $members | Where-Object { $_.userPrincipalName -eq $email }

        if ($alreadyAdmin) {
            Write-OK "$email is already Global Administrator"
        } else {
            # Get user object ID first
            $userResp = Invoke-AzRestMethod -Uri "https://graph.microsoft.com/v1.0/users/$email" -Method GET
            if ($userResp.StatusCode -ne 200) {
                Write-Warn "Cannot assign role — user $email not found (may not be created yet)"
                continue
            }
            $userId = ($userResp.Content | ConvertFrom-Json).id

            $roleBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId" } | ConvertTo-Json

            if (-not $DryRun) {
                $assignResp = Invoke-AzRestMethod `
                    -Uri "https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$globalAdminRoleId/members/`$ref" `
                    -Method POST `
                    -Payload $roleBody

                if ($assignResp.StatusCode -in 200, 204) {
                    Write-OK "Assigned Global Administrator to $email"
                } else {
                    Write-Warn "Assignment may have failed: $($assignResp.Content)"
                }
            } else {
                Write-OK "[DRY RUN] Would assign Global Administrator to $email"
            }
        }
    } catch {
        Write-Warn "Error assigning role to $email`: $_"
    }
}

# =============================================================================
# Phase 5 — Clean Up Guest/EXT Privileged Roles
# =============================================================================
if (-not $SkipCleanup) {
    Write-Step "Removing privileged roles from guest (#EXT#) accounts..."

    $guestAdmins | ForEach-Object {
        $assignment = $_
        Write-Info "Removing: $($assignment.SignInName) | $($assignment.RoleDefinitionName)"

        if (-not $DryRun) {
            try {
                Remove-AzRoleAssignment `
                    -ObjectId $assignment.ObjectId `
                    -RoleDefinitionName $assignment.RoleDefinitionName `
                    -Scope $assignment.Scope `
                    -ErrorAction Stop
                Write-OK "Removed role from $($assignment.SignInName)"
            } catch {
                Write-Warn "Could not remove role: $_ (may need to remove manually in portal)"
            }
        } else {
            Write-OK "[DRY RUN] Would remove: $($assignment.SignInName) | $($assignment.RoleDefinitionName)"
        }
    }
} else {
    Write-Info "Skipping guest role cleanup (--SkipCleanup specified)"
}

# =============================================================================
# Phase 6 — Create Service Principals
# =============================================================================
Write-Step "Creating service principals for automation..."

$spConfigs = @(
    @{
        Name        = "claude-mcp-sp"
        Role        = "Contributor"
        Description = "Claude Code Azure MCP server — read/manage Azure resources"
    },
    @{
        Name        = "n8n-automation-sp"
        Role        = "Reader"
        Description = "n8n workflow automation — read Azure resources, trigger Functions"
    }
)

$spOutputs = @{}

foreach ($sp in $spConfigs) {
    Write-Info "Creating SP: $($sp.Name)"

    # Check if already exists
    $existingSP = Get-AzADServicePrincipal -DisplayName $sp.Name -ErrorAction SilentlyContinue

    if ($existingSP) {
        Write-OK "$($sp.Name) already exists (appId: $($existingSP.AppId))"
        Write-Warn "  To rotate credentials: az ad app credential reset --id $($existingSP.AppId)"
    } else {
        if (-not $DryRun) {
            try {
                $newSP = New-AzADServicePrincipal `
                    -DisplayName $sp.Name `
                    -Role $sp.Role `
                    -Scope "/subscriptions/$subId" `
                    -Description $sp.Description

                $spOutputs[$sp.Name] = @{
                    AppId       = $newSP.AppId
                    TenantId    = $tenantId
                    Secret      = $newSP.PasswordCredentials[0].SecretText
                    DisplayName = $sp.Name
                }

                Write-OK "Created: $($sp.Name) (appId: $($newSP.AppId))"
            } catch {
                Write-Warn "Failed to create $($sp.Name): $_"
            }
        } else {
            Write-OK "[DRY RUN] Would create SP: $($sp.Name) with $($sp.Role) on subscription"
        }
    }
}

# =============================================================================
# Phase 7 — Fix User Consent Settings
# =============================================================================
Write-Step "Checking user consent settings (for ChatGPT/OAuth app access)..."

try {
    $authPolicyResp = Invoke-AzRestMethod `
        -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" `
        -Method GET

    $authPolicy = $authPolicyResp.Content | ConvertFrom-Json
    $consentSetting = $authPolicy.defaultUserRolePermissions.allowedToCreateApps

    Write-Info "Current user consent for apps: $($authPolicy.defaultUserRolePermissions.permissionGrantPoliciesAssigned -join ', ')"

    # Set to allow user consent for verified publisher apps
    $consentBody = @{
        defaultUserRolePermissions = @{
            permissionGrantPoliciesAssigned = @("ManagePermissionGrantsForSelf.microsoft-user-default-legacy")
        }
    } | ConvertTo-Json -Depth 3

    if (-not $DryRun) {
        $updateResp = Invoke-AzRestMethod `
            -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" `
            -Method PATCH `
            -Payload $consentBody

        if ($updateResp.StatusCode -in 200, 204) {
            Write-OK "User consent policy updated — users can now consent to verified publisher apps"
            Write-OK "ChatGPT, OpenAI, and other Microsoft-verified apps will no longer require admin approval"
        } else {
            Write-Warn "Consent policy update response: $($updateResp.StatusCode) — $($updateResp.Content)"
        }
    } else {
        Write-OK "[DRY RUN] Would enable user consent for verified publisher apps"
    }
} catch {
    Write-Warn "Could not update consent policy: $_ (may need to do this in portal)"
    Write-Info "Portal path: Entra ID → Enterprise applications → Consent and permissions → User consent settings"
}

# =============================================================================
# Summary Report
# =============================================================================
Write-Host "`n"
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Tenant:        $tenantId  ($TenantDomain)" -ForegroundColor White
Write-Host "  Subscription:  $subName  ($subId)" -ForegroundColor White
Write-Host ""

if ($spOutputs.Count -gt 0) {
    Write-Host "  ── Service Principal Credentials ──────────────────────────────" -ForegroundColor Yellow
    Write-Host "  SAVE THESE — secrets will not be shown again" -ForegroundColor Red
    Write-Host ""

    foreach ($spName in $spOutputs.Keys) {
        $sp = $spOutputs[$spName]
        Write-Host "  [$spName]" -ForegroundColor Yellow
        Write-Host "  AZURE_TENANT_ID=$($sp.TenantId)"
        Write-Host "  AZURE_CLIENT_ID=$($sp.AppId)"
        Write-Host "  AZURE_CLIENT_SECRET=$($sp.Secret)"
        Write-Host ""
    }

    Write-Host "  ── Claude MCP Config (~/.claude.json azure server env) ────────" -ForegroundColor Yellow
    if ($spOutputs["claude-mcp-sp"]) {
        $mcp = $spOutputs["claude-mcp-sp"]
        Write-Host @"
  "env": {
    "AZURE_TENANT_ID": "$($mcp.TenantId)",
    "AZURE_CLIENT_ID": "$($mcp.AppId)",
    "AZURE_CLIENT_SECRET": "$($mcp.Secret)"
  }
"@ -ForegroundColor Gray
    }
}

Write-Host "  ── Next Steps ──────────────────────────────────────────────────" -ForegroundColor Yellow
Write-Host "  1. Sign into portal.azure.com as will@willbracken.com (new native account)"
Write-Host "  2. Change temp password on first login"
Write-Host "  3. Test: az login --tenant $TenantDomain --use-device-code"
Write-Host "  4. Paste claude-mcp-sp credentials to Claude Code to enable Azure MCP"
Write-Host "  5. Verify ChatGPT/OpenAI apps no longer show admin approval prompt"
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
