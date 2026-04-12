param(
    [string]$subscriptionId = (az account show --query id -o tsv)
)

Write-Host "Ensure you run 'az login' before running this script."

# 1. Identity & Access Management (RBAC)
Write-Host "Assigning Owner to william3bracken..."
az role assignment create --assignee "william3bracken@..." --role "Owner" --scope "/subscriptions/$subscriptionId"

Write-Host "Assigning Contributor to willbracken33..."
az role assignment create --assignee "willbracken33@..." --role "Contributor" --scope "/subscriptions/$subscriptionId"

# 2. GitHub CI/CD OIDC Integration
Write-Host "Creating User Assigned Identity for GitHub Actions..."
$identity = az identity create --name "github-actions-identity" --resource-group "familyos-rg" | ConvertFrom-Json
$clientId = $identity.clientId
$objectId = $identity.principalId

Write-Host "Assigning Contributor to Identity for deployments..."
az role assignment create --assignee $objectId --role "Contributor" --scope "/subscriptions/$subscriptionId/resourceGroups/familyos-rg"

Write-Host "Creating Federated Credential..."
# Replace BrackenW3/azure_infrastructure with your repo name
az identity federated-credential create --name "github-oidc" --identity-name "github-actions-identity" `
  --resource-group "familyos-rg" --issuer "https://token.actions.githubusercontent.com" `
  --subject "repo:BrackenW3/Azure_GitHub:ref:refs/heads/main" `
  --audiences "api://AzureADTokenExchange"

Write-Host "GitHub OIDC Setup complete. Use Client ID $clientId in your workflows."
