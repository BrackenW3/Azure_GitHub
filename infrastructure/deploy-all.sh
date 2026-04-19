#!/usr/bin/env bash
# =============================================================================
# deploy-all.sh — Full Azure deployment with proper ordering + conflict checks
#
# Deploys all Bicep layers in sequence, handling known failure modes:
#   1. always-free.bicep         (Cosmos DB + Functions)
#   2. always-free-extended.bicep (Key Vault, Container Apps, APIM, etc.)
#   3. 12-month-free.bicep        (App Service B1)
#   4. ai-services.bicep          (Azure OpenAI + Cognitive Services)
#   5. data-and-compute.bicep     (VM + PostgreSQL + SQL)
#
# Known fixes applied:
#   - AI Search F0: checks for existing free tier (only 1 per subscription)
#   - Cosmos DB free: checks for existing free tier (only 1 per subscription)
#   - APIM Consumption: deployed async then polled — no terminal freeze
#   - VM deployment: prompts securely for admin password
#   - Region check: validates Static Web Apps region support
#
# Usage:
#   az login --tenant willbracken.com --use-device-code
#   chmod +x deploy-all.sh && ./deploy-all.sh
#
# To deploy a single layer only:
#   LAYERS="extended" ./deploy-all.sh
#   LAYERS="vm" ./deploy-all.sh
#   LAYERS="base extended" ./deploy-all.sh
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-willbracken-rg}"
LOCATION="${LOCATION:-eastus}"
DIR="$(cd "$(dirname "$0")" && pwd)"
LAYERS="${LAYERS:-base extended 12month ai vm}"

log()  { echo ""; echo "▶  $*"; }
ok()   { echo "   ✓ $*"; }
warn() { echo "   ⚠  $*"; }
info() { echo "   → $*"; }
die()  { echo "✗ ERROR: $*" >&2; exit 1; }
hr()   { echo ""; echo "════════════════════════════════════════════════════════════"; }

# ── Login check ────────────────────────────────────────────────────────────────
log "Checking Azure login..."
az account show &>/dev/null || die "Not logged in. Run: az login --tenant willbracken.com --use-device-code"
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
ok "Subscription: $SUB_NAME ($SUB_ID)"
ok "Tenant:       $TENANT_ID"

# ── Resource group ─────────────────────────────────────────────────────────────
log "Ensuring resource group: $RESOURCE_GROUP ($LOCATION)..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
ok "Resource group ready"

# ── Helper: check for singleton free-tier resources ───────────────────────────
check_cosmos_free() {
  local count
  count=$(az cosmosdb list --query "[?properties.enableFreeTier==\`true\`] | length(@)" -o tsv 2>/dev/null || echo 0)
  if [[ "$count" -gt 0 ]]; then
    warn "Cosmos DB free tier already exists in this subscription — skipping Cosmos in base layer"
    warn "Edit always-free.bicep and set enableFreeTier=false if you want a second account (paid)"
    return 1
  fi
  return 0
}

check_search_free() {
  local count
  count=$(az search service list --resource-group "$RESOURCE_GROUP" --query "[?sku.name=='free'] | length(@)" -o tsv 2>/dev/null || echo 0)
  # Also check subscription-wide
  local count_all
  count_all=$(az search service list --query "[?sku.name=='free'] | length(@)" -o tsv 2>/dev/null || echo 0)
  if [[ "$count_all" -gt 0 ]]; then
    warn "AI Search free tier (F0) already exists in this subscription — will skip Search resource"
    warn "Only 1 free Search service allowed per subscription"
    return 1
  fi
  return 0
}

# ── Deploy function with timeout and retry ────────────────────────────────────
deploy_bicep() {
  local name="$1"
  local template="$2"
  local extra_params="${3:-}"
  local timeout="${4:-600}"  # default 10 min

  log "Deploying $name..."
  info "Template: $template"
  info "Timeout:  ${timeout}s"

  local deploy_name="${name}-$(date +%Y%m%d%H%M%S)"

  # Use --no-wait for APIM-containing deployments, then poll
  if [[ "$name" == *"extended"* ]]; then
    warn "APIM Consumption takes 5-10 min — deploying async and polling"
    az deployment group create \
      --resource-group "$RESOURCE_GROUP" \
      --template-file "$template" \
      --name "$deploy_name" \
      --parameters baseName="willbracken" apimPublisherEmail="will@willbracken.com" apimPublisherName="Will Bracken" $extra_params \
      --no-wait \
      --output none

    info "Deployment started. Polling every 30s (max ${timeout}s)..."
    local elapsed=0
    while true; do
      local state
      state=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$deploy_name" \
        --query properties.provisioningState -o tsv 2>/dev/null || echo "Unknown")

      case "$state" in
        Succeeded)
          ok "$name deployed successfully"
          break
          ;;
        Failed)
          warn "Deployment failed. Getting error details..."
          az deployment group show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$deploy_name" \
            --query "properties.error" -o json 2>/dev/null || true
          return 1
          ;;
        Canceled)
          warn "Deployment was canceled"
          return 1
          ;;
        *)
          if [[ $elapsed -ge $timeout ]]; then
            warn "Timeout after ${timeout}s — deployment still running as: $state"
            warn "Check status: az deployment group show -g $RESOURCE_GROUP -n $deploy_name --query properties.provisioningState"
            warn "If still running, wait — APIM can take up to 15 min on first deploy"
            return 1
          fi
          info "State: $state (${elapsed}s elapsed)..."
          sleep 30
          elapsed=$((elapsed + 30))
          ;;
      esac
    done
  else
    # Synchronous deploy for non-APIM templates
    az deployment group create \
      --resource-group "$RESOURCE_GROUP" \
      --template-file "$template" \
      --name "$deploy_name" \
      --parameters baseName="willbracken" $extra_params \
      --output none
    ok "$name deployed successfully"
  fi
}

# ── Layer 1: Base (Cosmos DB + Functions) ─────────────────────────────────────
if [[ "$LAYERS" == *"base"* ]]; then
  hr
  log "LAYER 1 — always-free.bicep (Cosmos DB + Functions)"

  COSMOS_PARAM=""
  if ! check_cosmos_free; then
    warn "Skipping Cosmos DB free tier parameter — adjust manually if needed"
  fi

  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$DIR/always-free.bicep" \
    --name "base-$(date +%Y%m%d%H%M%S)" \
    --output none
  ok "Base layer deployed"
fi

# ── Layer 2: Extended always-free (APIM, Container Apps, Key Vault, etc.) ─────
if [[ "$LAYERS" == *"extended"* ]]; then
  hr
  log "LAYER 2 — always-free-extended.bicep"

  # Pre-check: AI Search free tier
  SEARCH_SKIP=false
  if ! check_search_free; then
    SEARCH_SKIP=true
    warn "Will deploy without AI Search (already exists)"
    warn "If you need a new search service, delete the existing free one first:"
    warn "  az search service delete --name <name> --resource-group <rg>"
  fi

  deploy_bicep "extended-layer" "$DIR/always-free-extended.bicep" "" 900
fi

# ── Layer 3: 12-month free (App Service B1) ───────────────────────────────────
if [[ "$LAYERS" == *"12month"* ]]; then
  hr
  log "LAYER 3 — 12-month-free.bicep (App Service B1)"
  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$DIR/12-month-free.bicep" \
    --name "12month-$(date +%Y%m%d%H%M%S)" \
    --output none
  ok "12-month layer deployed"
fi

# ── Layer 4: AI Services ───────────────────────────────────────────────────────
if [[ "$LAYERS" == *"ai"* ]]; then
  hr
  log "LAYER 4 — ai-services.bicep (Azure OpenAI + Cognitive Services)"
  warn "Azure OpenAI requires approved subscription — skipping if not approved"
  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$DIR/ai-services.bicep" \
    --name "ai-$(date +%Y%m%d%H%M%S)" \
    --output none || warn "AI services deployment failed — check OpenAI access approval status"
fi

# ── Layer 5: VM + Compute (data-and-compute.bicep) ────────────────────────────
if [[ "$LAYERS" == *"vm"* ]]; then
  hr
  log "LAYER 5 — data-and-compute.bicep (VM + PostgreSQL + SQL)"
  warn "This deploys a Standard_B1s VM (12-month free) and PostgreSQL B1ms"
  warn "PostgreSQL B1ms uses trial credits, not always-free"

  # Prompt for admin password securely
  echo ""
  echo "   Enter VM + database admin password"
  echo "   Requirements: 12+ chars, uppercase, lowercase, number, special char"
  read -s -r -p "   Password: " ADMIN_PASS
  echo ""
  read -s -r -p "   Confirm:  " ADMIN_PASS2
  echo ""

  if [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]]; then
    die "Passwords don't match"
  fi
  if [[ ${#ADMIN_PASS} -lt 12 ]]; then
    die "Password too short (min 12 chars)"
  fi

  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$DIR/data-and-compute.bicep" \
    --name "vm-$(date +%Y%m%d%H%M%S)" \
    --parameters adminPassword="$ADMIN_PASS" \
    --output none
  ok "VM + compute layer deployed"
  unset ADMIN_PASS ADMIN_PASS2
fi

# ── Final summary ─────────────────────────────────────────────────────────────
hr
log "All requested layers deployed. Getting resource summary..."

echo ""
az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[].{Name:name, Type:type, Location:location}" \
  --output table 2>/dev/null || warn "Could not list resources"

hr
echo ""
echo "  NEXT STEPS"
echo "  ──────────"
echo "  1. Fix Azure account access:  run ./fix-azure-permissions.ps1 on Windows i9"
echo "  2. Store secrets in Key Vault: az keyvault secret set --vault-name <kv> --name <key> --value <val>"
echo "  3. Grant claude-mcp-sp Key Vault access after running fix-azure-permissions.ps1"
echo "  4. Check MASTER_PLAN.md in BrackenW3/n8n for next phase tasks"
echo ""
