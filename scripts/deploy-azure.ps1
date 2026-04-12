<#
.SYNOPSIS
Deploys Azure infrastructure across different cost tiers.

.DESCRIPTION
This script checks for the Azure CLI, prompts for login, and provides functions to deploy 
three distinct tiers: Always Free, 12-Month Free, and a 30-Day Spot VM burn.

.EXAMPLE
.\deploy-azure.ps1 -Tier AlwaysFree -ResourceGroup my-free-rg -Location eastus
#>

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet('AlwaysFree', '12MonthFree', '30DayBurn')]
    [string]$Tier,

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",
    
    [Parameter(Mandatory=$false)]
    [string]$SqlAdminPassword = "",

    [Parameter(Mandatory=$false)]
    [string]$VmAdminPassword = ""
)

$ErrorActionPreference = "Stop"

function Check-AzCli {
    Write-Host "Checking for Azure CLI..." -ForegroundColor Cyan
    try {
        # Check if az command exists
        $command = Get-Command az -ErrorAction SilentlyContinue
        if (-not $command) {
            throw "Azure CLI not found."
        }
        Write-Host "Azure CLI is installed." -ForegroundColor Green
    }
    catch {
        Write-Host "Azure CLI is NOT installed or not in PATH." -ForegroundColor Red
        Write-Host "Please install it from: https://aka.ms/installazurecliwindows" -ForegroundColor Yellow
        exit 1
    }
}

function Check-AzLogin {
    Write-Host "Checking Azure login status..." -ForegroundColor Cyan
    try {
        $account = az account show --query name -o tsv 2>&1
        if ($account -match "Please run 'az login' to setup account" -or $LASTEXITCODE -ne 0) {
            throw "Not logged in."
        }
        Write-Host "Logged in to subscription: $account" -ForegroundColor Green
    }
    catch {
        Write-Host "You are not logged in to Azure." -ForegroundColor Yellow
        $response = Read-Host "Would you like to run 'az login' now? (Y/N)"
        if ($response -eq 'Y' -or $response -eq 'y') {
            az login
        }
        else {
            Write-Host "Deployment aborted. Please log in first." -ForegroundColor Red
            exit 1
        }
    }
}

function Ensure-ResourceGroup {
    param([string]$RgName, [string]$RgLocation)
    Write-Host "Ensuring Resource Group '$RgName' exists in '$RgLocation'..." -ForegroundColor Cyan
    $exists = az group exists --name $RgName
    if ($exists -eq "true") {
        Write-Host "Resource Group already exists." -ForegroundColor Green
    }
    else {
        az group create --name $RgName --location $RgLocation | Out-Null
        Write-Host "Created Resource Group: $RgName" -ForegroundColor Green
    }
}

function Deploy-AlwaysFree {
    param([string]$RgName)
    Write-Host "Deploying Always Free Tier..." -ForegroundColor Cyan
    $templateFile = Join-Path $PSScriptRoot "..\infrastructure\always-free.bicep"
    az deployment group create --resource-group $RgName --template-file $templateFile
    Write-Host "Always Free Tier deployment complete." -ForegroundColor Green
}

function Deploy-12MonthFree {
    param([string]$RgName, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Password)) {
        Write-Host "Error: -SqlAdminPassword is required for the 12-Month Free tier." -ForegroundColor Red
        exit 1
    }
    Write-Host "Deploying 12-Month Free Tier..." -ForegroundColor Cyan
    $templateFile = Join-Path $PSScriptRoot "..\infrastructure\12-month-free.bicep"
    az deployment group create --resource-group $RgName --template-file $templateFile --parameters sqlAdminPassword=$Password
    Write-Host "12-Month Free Tier deployment complete." -ForegroundColor Green
}

function Deploy-30DayBurn {
    param([string]$RgName, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Password)) {
        Write-Host "Error: -VmAdminPassword is required for the 30-Day Burn tier." -ForegroundColor Red
        exit 1
    }
    Write-Host "Deploying 30-Day Burn Tier..." -ForegroundColor Cyan
    $templateFile = Join-Path $PSScriptRoot "..\infrastructure\30-day-burn.bicep"
    az deployment group create --resource-group $RgName --template-file $templateFile --parameters adminPassword=$Password
    Write-Host "30-Day Burn Tier deployment complete." -ForegroundColor Green
}

# Main Execution
Check-AzCli
Check-AzLogin
Ensure-ResourceGroup -RgName $ResourceGroup -RgLocation $Location

switch ($Tier) {
    'AlwaysFree' { Deploy-AlwaysFree -RgName $ResourceGroup }
    '12MonthFree' { Deploy-12MonthFree -RgName $ResourceGroup -Password $SqlAdminPassword }
    '30DayBurn' { Deploy-30DayBurn -RgName $ResourceGroup -Password $VmAdminPassword }
}

Write-Host "All requested operations finished." -ForegroundColor Cyan
