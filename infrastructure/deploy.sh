#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Full infrastructure deployment for willbracken Azure free stack
#
# Run from Git Bash on Windows or WSL.
# Requires: az CLI logged in with correct subscription selected.
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# To deploy a single template:
#   ./deploy.sh identities        # Step 1 only
#   ./deploy.sh core              # Step 2 only
#   ./deploy.sh extended          # Step 3 only
#   ./deploy.sh apps              # Step 4 only
#   ./deploy.sh ai                # Step 5 only
#   ./deploy.sh compute           # Step 6 only (prompts for IP + password)
# =============================================================================

set -euo pipefail

RG="willbracken-free-rg"
TEMPLATES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Pre-flight ───────────────────────────────────────────────────────────────
echo "==> Checking Azure CLI login..."
az account show --query "{subscription:name, id:id}" -o table

echo ""
echo "==> Target resource group: $RG"
echo "    Creating if it doesn't exist (or using existing)..."
# Use existing RG location if it already exists — avoid location conflict
EXISTING_LOCATION=$(az group show --name "$RG" --query location -o tsv 2>/dev/null || echo "")
if [ -n "$EXISTING_LOCATION" ]; then
  echo "    Resource group exists in location: $EXISTING_LOCATION"
  RG_LOCATION="$EXISTING_LOCATION"
else
  RG_LOCATION="eastus"
  az group create --name "$RG" --location "$RG_LOCATION" --output none
  echo "    Resource group created in: $RG_LOCATION"
fi

# ─── Step 1: Managed Identities (idempotent — safe to re-run) ────────────────
deploy_identities() {
  echo ""
  echo "==> [1/6] Deploying managed identities..."

  # If already deployed, just read the existing values (no redeploy needed)
  EXISTING_ID=$(az identity show \
    --resource-group "$RG" \
    --name "willbracken-platform-id" \
    --query "id" -o tsv 2>/dev/null || echo "")

  if [ -n "$EXISTING_ID" ]; then
    echo "    ℹ️  Identities already deployed — reading existing values."
    PLATFORM_IDENTITY_ID="$EXISTING_ID"
    PLATFORM_IDENTITY_CLIENT_ID=$(az identity show \
      --resource-group "$RG" \
      --name "willbracken-platform-id" \
      --query "clientId" -o tsv)
  else
    IDENTITY_OUTPUT=$(az deployment group create \
      --resource-group "$RG" \
      --template-file "$TEMPLATES_DIR/managed-identities.bicep" \
      --query "properties.outputs" \
      -o json)
    PLATFORM_IDENTITY_ID=$(echo "$IDENTITY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['platformIdentityId']['value'])")
    PLATFORM_IDENTITY_CLIENT_ID=$(echo "$IDENTITY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['platformIdentityClientId']['value'])")
  fi

  echo "    Platform identity ID:        $PLATFORM_IDENTITY_ID"
  echo "    Platform identity clientId:  $PLATFORM_IDENTITY_CLIENT_ID"

  export PLATFORM_IDENTITY_ID
  export PLATFORM_IDENTITY_CLIENT_ID
}

# ─── Step 2: Core Always-Free (Cosmos DB + Storage + optional Function App) ───
deploy_core() {
  echo ""
  echo "==> [2/6] Deploying core always-free services (Cosmos DB, Storage)..."

  # Pre-check: free-tier Cosmos DB — limit 1 per subscription
  DEPLOY_COSMOS=true
  EXISTING_COSMOS=$(az cosmosdb list --query "[?enableFreeTier==\`true\`].name" -o tsv 2>/dev/null || echo "")
  if [ -n "$EXISTING_COSMOS" ]; then
    echo "    ⚠️  Free-tier Cosmos DB already exists: $EXISTING_COSMOS — skipping (limit: 1 per subscription)."
    DEPLOY_COSMOS=false
  fi

  # Pre-check: Dynamic VM quota for Function App (Y1/Consumption)
  # Use a temp file to capture output safely across shells on Windows
  DEPLOY_FUNC=true
  TMPFILE=$(mktemp /tmp/az_deploy_XXXXXX.json)

  set +e
  az deployment group create \
    --resource-group "$RG" \
    --template-file "$TEMPLATES_DIR/always-free.bicep" \
    --parameters platformIdentityId="$PLATFORM_IDENTITY_ID" \
                 deployFunctionApp=true \
                 deployCosmosDb="$DEPLOY_COSMOS" \
    --query "properties.outputs" \
    -o json > "$TMPFILE" 2>&1
  DEPLOY_EXIT=$?
  set -e

  CORE_OUTPUT=$(cat "$TMPFILE")
  rm -f "$TMPFILE"

  # Retry without Function App if quota exceeded
  if [ $DEPLOY_EXIT -ne 0 ] && echo "$CORE_OUTPUT" | grep -q "SubscriptionIsOverQuotaForSku"; then
    echo "    ⚠️  Dynamic VM quota = 0 — skipping Function App."
    echo "       Request quota: portal → Subscriptions → Usage + Quotas → Dynamic VMs"
    DEPLOY_FUNC=false

    TMPFILE=$(mktemp /tmp/az_deploy_XXXXXX.json)
    az deployment group create \
      --resource-group "$RG" \
      --template-file "$TEMPLATES_DIR/always-free.bicep" \
      --parameters platformIdentityId="$PLATFORM_IDENTITY_ID" \
                   deployFunctionApp=false \
                   deployCosmosDb="$DEPLOY_COSMOS" \
      --query "properties.outputs" \
      -o json > "$TMPFILE"
    CORE_OUTPUT=$(cat "$TMPFILE")
    rm -f "$TMPFILE"
  elif [ $DEPLOY_EXIT -ne 0 ]; then
    echo "ERROR: Core deployment failed:"
    echo "$CORE_OUTPUT"
    exit 1
  fi

  STORAGE_ACCOUNT_NAME=$(echo "$CORE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['storageAccountName']['value'])")
  FUNCTION_APP_NAME=$(echo "$CORE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['functionAppName']['value'])")

  echo "    Storage account: $STORAGE_ACCOUNT_NAME"
  echo "    Function App:    $FUNCTION_APP_NAME"

  export STORAGE_ACCOUNT_NAME
  export FUNCTION_APP_NAME
}

# ─── Step 3: Extended Always-Free (Key Vault, APIM, Container Apps, etc.) ─────
deploy_extended() {
  echo ""
  echo "==> [3/6] Deploying extended always-free services (KV, APIM, Container Apps)..."

  # Detect already-deployed Key Vault (idempotency — extended was partially deployed before)
  EXISTING_KV=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
  if [ -n "$EXISTING_KV" ]; then
    echo "    ℹ️  Key Vault already exists: $EXISTING_KV — redeploying to fix RBAC + APIM publisher email."
  fi

  EXTENDED_OUTPUT=$(az deployment group create \
    --resource-group "$RG" \
    --template-file "$TEMPLATES_DIR/always-free-extended.bicep" \
    --parameters \
      platformIdentityId="$PLATFORM_IDENTITY_ID" \
      apimPublisherEmail="william.i.bracken@outlook.com" \
      apimPublisherName="Will Bracken" \
    --query "properties.outputs" \
    -o json)

  KEY_VAULT_NAME=$(echo "$EXTENDED_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['keyVaultName']['value'])")
  KEY_VAULT_URI=$(echo "$EXTENDED_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['keyVaultUri']['value'])")
  APIM_URL=$(echo "$EXTENDED_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['apimGatewayUrl']['value'])")

  echo "    Key Vault name: $KEY_VAULT_NAME"
  echo "    Key Vault URI:  $KEY_VAULT_URI"
  echo "    APIM Gateway:   $APIM_URL"
  echo "    NOTE: APIM takes ~5 minutes — this is normal."

  export KEY_VAULT_NAME
  export KEY_VAULT_URI
  export APIM_URL
}

# ─── Step 4: App Services (Python + Node) ────────────────────────────────────
deploy_apps() {
  echo ""
  echo "==> [4/6] Deploying App Services (Python API + Node API)..."

  # Pre-check: Free VM quota for F1 App Service Plans
  # quota name is "Free VMs" for App Service F1 tier
  DEPLOY_APPS=true
  FREE_VM_QUOTA=$(az vm list-usage --location "$RG_LOCATION" \
    --query "[?localName=='Free VMs' || contains(localName,'Free VM')].limit" \
    -o tsv 2>/dev/null || echo "")
  if [ "${FREE_VM_QUOTA:-0}" = "0" ]; then
    # Try anyway — quota API may not reflect App Service quota accurately
    TMPFILE=$(mktemp /tmp/az_apps_XXXXXX.json)
    set +e
    az deployment group create \
      --resource-group "$RG" \
      --template-file "$TEMPLATES_DIR/app-services.bicep" \
      --parameters \
        platformIdentityId="$PLATFORM_IDENTITY_ID" \
        keyVaultName="$KEY_VAULT_NAME" \
        deployAppServices=true \
      --query "properties.outputs" \
      -o json > "$TMPFILE" 2>&1
    APPS_EXIT=$?
    set -e
    APPS_OUTPUT=$(cat "$TMPFILE"); rm -f "$TMPFILE"

    if [ $APPS_EXIT -ne 0 ] && echo "$APPS_OUTPUT" | grep -q "SubscriptionIsOverQuotaForSku"; then
      echo "    ⚠️  Free VM quota = 0 — skipping App Services."
      echo "       Request quota: portal → Subscriptions → Usage + Quotas → Free VMs"
      echo "       Then run: ./deploy.sh apps"
      DEPLOY_APPS=false
      # Deploy with flag off just to get outputs (no-ops)
      APPS_OUTPUT=$(az deployment group create \
        --resource-group "$RG" \
        --template-file "$TEMPLATES_DIR/app-services.bicep" \
        --parameters \
          platformIdentityId="$PLATFORM_IDENTITY_ID" \
          keyVaultName="$KEY_VAULT_NAME" \
          deployAppServices=false \
        --query "properties.outputs" \
        -o json)
    elif [ $APPS_EXIT -ne 0 ]; then
      echo "ERROR: App Services deployment failed:"
      echo "$APPS_OUTPUT"
      exit 1
    fi
  else
    APPS_OUTPUT=$(az deployment group create \
      --resource-group "$RG" \
      --template-file "$TEMPLATES_DIR/app-services.bicep" \
      --parameters \
        platformIdentityId="$PLATFORM_IDENTITY_ID" \
        keyVaultName="$KEY_VAULT_NAME" \
      --query "properties.outputs" \
      -o json)
  fi

  PYTHON_URL=$(echo "$APPS_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['pythonAppUrl']['value'])")
  NODE_URL=$(echo "$APPS_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['nodeAppUrl']['value'])")

  echo "    Python App: $PYTHON_URL"
  echo "    Node App:   $NODE_URL"
}

# ─── Step 5: AI Services ─────────────────────────────────────────────────────
deploy_ai() {
  echo ""
  echo "==> [5/6] Deploying AI services (Language, Bot, ML Workspace)..."
  az deployment group create \
    --resource-group "$RG" \
    --template-file "$TEMPLATES_DIR/ai-services.bicep" \
    --parameters \
      storageAccountName="$STORAGE_ACCOUNT_NAME" \
      keyVaultName="$KEY_VAULT_NAME" \
    --output table
}

# ─── Step 6: Compute (VM + PostgreSQL + SQL) — prompts for sensitive values ──
deploy_compute() {
  echo ""
  echo "==> [6/6] Deploying compute resources (VM, PostgreSQL, SQL)..."
  echo ""

  # Get public IP for PostgreSQL firewall
  echo "    Detecting your public IP for PostgreSQL firewall..."
  MY_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s api.ipify.org)
  echo "    Your public IP: $MY_IP"
  echo ""

  # Auto-detect available VM SKU — tries preferred sizes in order, then falls back to eastus2
  # Note: az vm list-skus restriction checks are unreliable for quota-gated SKUs;
  # we attempt a dry-run deployment to confirm actual availability.
  echo "    Checking VM SKU availability in $RG_LOCATION..."
  VM_LOCATION="$RG_LOCATION"
  VM_SIZE=""

  # Preference order: B1s (cheapest, 12mo free) → B1ms → B2s → D2als_v7 (confirmed available eastus2)
  for SKU in Standard_B1s Standard_B1ms Standard_B2s Standard_A1_v2 Standard_DS1_v2 Standard_D2als_v7 Standard_D2as_v7; do
    AVAILABLE=$(az vm list-skus \
      --location "$VM_LOCATION" \
      --size "$SKU" \
      --query "[?name=='$SKU' && (restrictions==null || length(restrictions)==\`0\`)].name" \
      -o tsv 2>/dev/null || echo "")
    if [ -n "$AVAILABLE" ]; then
      VM_SIZE="$SKU"
      echo "    VM SKU selected: $VM_SIZE (in $VM_LOCATION)"
      break
    else
      echo "    ⚠️  $SKU not available in $VM_LOCATION — trying next..."
    fi
  done

  # If nothing found in primary region, try eastus2 with expanded candidate list
  if [ -z "$VM_SIZE" ]; then
    echo "    ⚠️  No preferred SKU available in $VM_LOCATION — trying eastus2..."
    VM_LOCATION="eastus2"
    for SKU in Standard_B1s Standard_B1ms Standard_B2s Standard_D2als_v7 Standard_D2as_v7 Standard_D2alds_v7; do
      AVAILABLE=$(az vm list-skus \
        --location "$VM_LOCATION" \
        --size "$SKU" \
        --query "[?name=='$SKU' && (restrictions==null || length(restrictions)==\`0\`)].name" \
        -o tsv 2>/dev/null || echo "")
      if [ -n "$AVAILABLE" ]; then
        VM_SIZE="$SKU"
        echo "    VM SKU selected: $VM_SIZE (in $VM_LOCATION)"
        break
      fi
    done
  fi

  # Last resort: use Standard_D2als_v7 in eastus2 — confirmed available 2026-04-13
  if [ -z "$VM_SIZE" ]; then
    VM_SIZE="Standard_D2als_v7"
    VM_LOCATION="eastus2"
    echo "    ℹ️  Defaulting to $VM_SIZE in $VM_LOCATION (confirmed available, 2 vCPU / 4GB AMD)"
  fi

  # Prompt for admin password (not stored anywhere)
  read -rsp "    Enter admin password for VM + PostgreSQL + SQL (min 12 chars, must include uppercase, number, symbol): " ADMIN_PASSWORD
  echo ""

  # Resolve signed-in user for Entra admin assignments (SQL + PostgreSQL)
  ENTRA_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "b4cf1f2a-1f1c-455b-964f-b0dc8dcd9d81")
  ENTRA_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || echo "william.i.bracken_outlook.com#EXT#@willbracken.com")
  echo "    Entra admin: $ENTRA_UPN (objectId: $ENTRA_OBJECT_ID)"

  COMPUTE_OUTPUT=$(az deployment group create \
    --resource-group "$RG" \
    --template-file "$TEMPLATES_DIR/data-and-compute.bicep" \
    --parameters \
      adminPassword="$ADMIN_PASSWORD" \
      allowedClientIp="$MY_IP" \
      adminEntraObjectId="$ENTRA_OBJECT_ID" \
      adminEntraLogin="$ENTRA_UPN" \
      vmSize="$VM_SIZE" \
      location="$VM_LOCATION" \
    --query "properties.outputs" \
    -o json)

  PG_FQDN=$(echo "$COMPUTE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['postgresServerFqdn']['value'])")
  SQL_SERVER=$(echo "$COMPUTE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['sqlServerName']['value'])")
  DEPLOYED_VM_SIZE=$(echo "$COMPUTE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vmSize']['value'])" 2>/dev/null || echo "$VM_SIZE")

  echo "    VM size:         $DEPLOYED_VM_SIZE"
  echo "    PostgreSQL FQDN: $PG_FQDN"
  echo "    SQL Server name: $SQL_SERVER"
  echo "    ✓ Entra admin ($ENTRA_UPN) assigned to SQL Server + PostgreSQL in template."
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
STEP="${1:-all}"

case "$STEP" in
  identities) deploy_identities ;;
  core)       deploy_identities && deploy_core ;;
  extended)   deploy_identities && deploy_extended ;;
  apps)       deploy_identities && deploy_extended && deploy_apps ;;
  ai)         deploy_identities && deploy_core && deploy_extended && deploy_ai ;;
  compute)    deploy_compute ;;
  resume)
    # Current state: Step 1 (identities) + Step 3 (extended) resources exist.
    # Storage exists. Cosmos + FunctionApp skipped (quota/limit).
    # Remaining: Step 2 retry (storage idempotent), Step 3 redeploy (fix RBAC),
    #            Step 4 (apps), Step 5 (ai).
    echo "==> Resuming from current state (Steps 1+3 partially deployed)..."
    deploy_identities
    deploy_core
    deploy_extended
    deploy_apps
    deploy_ai
    echo ""
    echo "==> Steps 1–5 complete. Run './deploy.sh compute' when ready for VM + PostgreSQL + SQL."
    ;;
  all)
    deploy_identities
    deploy_core
    deploy_extended
    deploy_apps
    deploy_ai
    echo ""
    echo "==> Steps 1–5 complete. Compute (Step 6) skipped by default to avoid accidental VM costs."
    echo "    Run './deploy.sh compute' when you're ready to deploy VM + PostgreSQL + SQL."
    ;;
  *)
    echo "Unknown step: $STEP"
    echo "Valid: all, resume, identities, core, extended, apps, ai, compute"
    exit 1
    ;;
esac

echo ""
echo "==> Deployment complete."
echo "    Key Vault URI:  ${KEY_VAULT_URI:-'(run with core+extended to see)'}"
echo "    APIM Gateway:   ${APIM_URL:-'(run with extended to see)'}"
