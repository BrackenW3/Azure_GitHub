param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName = "familyos-rg",
    [string]$Location = "eastus"
)

$az = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"

Write-Host "Checking Azure Login..."
& $az account show > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "You are not logged into Azure. Please run: & `"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd`" login" -ForegroundColor Yellow
    exit 1
}

Write-Host "Creating Resource Group: $ResourceGroupName in $Location..."
& $az group create --name $ResourceGroupName --location $Location -o none

Write-Host "Deploying App Services (Free Tiers)..."
& $az deployment group create --resource-group $ResourceGroupName --template-file "C:\Users\User\Azure_GitHub\infrastructure\app-services.bicep"

Write-Host "Deploying AI & Cognitive Services (Free Tiers)..."
& $az deployment group create --resource-group $ResourceGroupName --template-file "C:\Users\User\Azure_GitHub\infrastructure\ai-services.bicep"

Write-Host "Deployment completed successfully!"
