#!/usr/bin/env bash
# =============================================================================
# deploy-always-free-extended.sh
# Deploys the extended always-free Azure infrastructure layer.
#
# Prerequisites:
#   az login --tenant willbracken.com --use-device-code
#   (or service principal auth if claude-mcp-sp is set up)
#
# What this deploys (all $0/month, no expiry):
#   • Key Vault (secrets management)
#   • Container Apps Environment + placeholder app
#   • Log Analytics Workspace (5GB/month free)
#   • Static Web Apps (free hosting)
#   • API Management Consumption (1M calls/month)
#   • Event Grid System Topic
#   • Service Bus Basic + email-processing queue
#   • AI Search Free F0 tier
#   • App Configuration (feature flags)
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-willbracken-rg}"
LOCATION="${LOCATION:-eastus}"
TEMPLATE="$(dirname "$0")/always-free-extended.bicep"
APIM_EMAIL="${APIM_EMAIL:-will@willbracken.com}"
APIM_NAME="${APIM_NAME:-Will Bracken}"

log()  { echo ""; echo "▶  $*"; }
ok()   { echo "   ✓ $*"; }
warn() { echo "   ⚠  $*"; }
die()  { echo "✗ ERROR: $*" >&2; exit 1; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────
log "Checking Azure login..."
az account show &>/dev/null || die "Not logged in. Run: az login --tenant willbracken.com --use-device-code"

SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ok "Subscription: $SUB_NAME"
ok "Tenant:       $TENANT_ID"

# ── Resource group ─────────────────────────────────────────────────────────────
log "Ensuring resource group: $RESOURCE_GROUP ($LOCATION)..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none \
  && ok "Resource group ready"

# ── APIM warning ──────────────────────────────────────────────────────────────
warn "API Management (Consumption) takes 5-10 minutes to provision — this is normal."
warn "The deployment will wait. Don't cancel."

# ── Deploy ────────────────────────────────────────────────────────────────────
log "Deploying always-free-extended.bicep..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE" \
  --parameters \
      baseName="willbracken" \
      apimPublisherEmail="$APIM_EMAIL" \
      apimPublisherName="$APIM_NAME" \
  --output json)

ok "Deployment complete!"

# ── Print outputs ─────────────────────────────────────────────────────────────
log "Resource endpoints:"

KV_URI=$(echo "$DEPLOYMENT_OUTPUT"        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs'].get('keyVaultUri',{}).get('value','—'))" 2>/dev/null || echo "—")
CA_URL=$(echo "$DEPLOYMENT_OUTPUT"        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs'].get('containerAppUrl',{}).get('value','—'))" 2>/dev/null || echo "—")
SWA_URL=$(echo "$DEPLOYMENT_OUTPUT"       | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs'].get('staticWebAppUrl',{}).get('value','—'))" 2>/dev/null || echo "—")
APIM_URL=$(echo "$DEPLOYMENT_OUTPUT"      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs'].get('apimGatewayUrl',{}).get('value','—'))" 2>/dev/null || echo "—")
SEARCH_URL=$(echo "$DEPLOYMENT_OUTPUT"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs'].get('aiSearchEndpoint',{}).get('value','—'))" 2>/dev/null || echo "—")
APPCONFIG_URL=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs'].get('appConfigEndpoint',{}).get('value','—'))" 2>/dev/null || echo "—")
SB_CONN=$(echo "$DEPLOYMENT_OUTPUT"       | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['properties']['outputs'].get('serviceBusConnectionString',{}).get('value','—'))" 2>/dev/null || echo "—")

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  ALWAYS-FREE EXTENDED LAYER — DEPLOYED"
echo "════════════════════════════════════════════════════════════════════"
echo "  Key Vault URI:         $KV_URI"
echo "  Container App URL:     $CA_URL"
echo "  Static Web App URL:    $SWA_URL"
echo "  API Management URL:    $APIM_URL"
echo "  AI Search Endpoint:    $SEARCH_URL"
echo "  App Config Endpoint:   $APPCONFIG_URL"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Next steps:"
echo "  1. Store API keys in Key Vault:  az keyvault secret set --vault-name <kv-name> --name <secret> --value <value>"
echo "  2. Grant claude-mcp-sp access:   az role assignment create --role 'Key Vault Secrets User' --assignee <sp-client-id> --scope <kv-id>"
echo "  3. Update Container App image:   az containerapp update --name willbracken-app --resource-group $RESOURCE_GROUP --image <your-image>"
echo "  4. Link Static Web App to GitHub: az staticwebapp create --name willbracken-web --source <github-url> --branch main"
echo "  5. Paste Service Bus connection string to n8n if needed:"
echo "     $SB_CONN"
echo "════════════════════════════════════════════════════════════════════"
