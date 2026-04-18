#!/usr/bin/env bash
# =============================================================================
# deploy-vm-only.sh — Deploy ONLY the VM + data/compute layer
#
# Use this when the other layers are already deployed and you just need
# to get the familyos-b1s-vm + PostgreSQL + SQL running.
#
# Why this is separate:
#   - Requires a secure password (never stored in code)
#   - Uses 12-month free credits (Standard_B1s VM, PostgreSQL B1ms)
#   - Can be deployed independently without re-running other layers
#   - VM deployment sometimes needs a fresh resource group state
#
# Usage:
#   az login --tenant willbracken.com --use-device-code
#   chmod +x deploy-vm-only.sh && ./deploy-vm-only.sh
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-willbracken-rg}"
LOCATION="${LOCATION:-eastus}"
DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo ""; echo "▶  $*"; }
ok()   { echo "   ✓ $*"; }
warn() { echo "   ⚠  $*"; }
die()  { echo "✗ ERROR: $*" >&2; exit 1; }

# ── Login check ────────────────────────────────────────────────────────────────
log "Checking Azure login..."
az account show &>/dev/null || die "Not logged in. Run: az login --tenant willbracken.com --use-device-code"
SUB_NAME=$(az account show --query name -o tsv)
ok "Subscription: $SUB_NAME"

# ── Resource group ─────────────────────────────────────────────────────────────
log "Ensuring resource group: $RESOURCE_GROUP ($LOCATION)..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
ok "Resource group ready"

# ── Check for existing VM ─────────────────────────────────────────────────────
log "Checking for existing VM..."
EXISTING_VM=$(az vm list --resource-group "$RESOURCE_GROUP" --query "[?name=='familyos-b1s-vm'].name" -o tsv 2>/dev/null || echo "")
if [[ -n "$EXISTING_VM" ]]; then
  warn "VM 'familyos-b1s-vm' already exists in $RESOURCE_GROUP"
  warn "Options:"
  warn "  • To redeploy: az vm delete --resource-group $RESOURCE_GROUP --name familyos-b1s-vm --yes"
  warn "  • To just start: az vm start --resource-group $RESOURCE_GROUP --name familyos-b1s-vm"
  warn "  • To get IP: az vm show -g $RESOURCE_GROUP -n familyos-b1s-vm -d --query publicIps -o tsv"
  echo ""
  read -r -p "   Continue anyway and attempt redeployment? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
fi

# ── Warn about credit usage ───────────────────────────────────────────────────
log "Resource cost profile:"
echo ""
echo "   Standard_B1s VM    — FREE (12-month free tier, 750 hrs/mo)"
echo "   PostgreSQL B1ms    — Uses trial credits (~\$15/mo after trial)"
echo "   SQL Database S0    — FREE (useFreeLimit=true, 100K vCore-s/mo)"
echo "   VNet + Public IP   — FREE (basic tier)"
echo ""
read -r -p "   Proceed? [Y/n] " CONFIRM
[[ ! "$CONFIRM" =~ ^[Nn]$ ]] || exit 0

# ── Secure password prompt ────────────────────────────────────────────────────
log "Set admin credentials (used for VM SSH + PostgreSQL + SQL):"
echo "   Username: familyadmin (fixed in Bicep)"
echo "   Password requirements: 12+ chars, upper+lower+number+special"
echo ""

while true; do
  read -s -r -p "   Password: " ADMIN_PASS
  echo ""
  read -s -r -p "   Confirm:  " ADMIN_PASS2
  echo ""

  if [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]]; then
    warn "Passwords don't match — try again"
    continue
  fi
  if [[ ${#ADMIN_PASS} -lt 12 ]]; then
    warn "Password too short (min 12 chars) — try again"
    continue
  fi
  # Basic complexity check
  if ! echo "$ADMIN_PASS" | grep -qP '(?=.*[A-Z])(?=.*[a-z])(?=.*[0-9])(?=.*[^A-Za-z0-9])'; then
    warn "Password must contain uppercase, lowercase, number, and special character — try again"
    continue
  fi
  ok "Password accepted"
  break
done

# ── Deploy ────────────────────────────────────────────────────────────────────
log "Deploying data-and-compute.bicep..."
warn "VM provisioning takes 3-5 minutes — normal"

DEPLOY_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$DIR/data-and-compute.bicep" \
  --name "vm-$(date +%Y%m%d%H%M%S)" \
  --parameters adminPassword="$ADMIN_PASS" \
  --output json 2>&1) && DEPLOY_OK=true || DEPLOY_OK=false

unset ADMIN_PASS ADMIN_PASS2

if [[ "$DEPLOY_OK" == "false" ]]; then
  echo "$DEPLOY_OUTPUT" | tail -30
  die "VM deployment failed — see errors above"
fi

ok "Deployment complete!"

# ── Get outputs ───────────────────────────────────────────────────────────────
log "Getting VM public IP..."
VM_IP=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "familyos-b1s-vm" \
  --show-details \
  --query publicIps -o tsv 2>/dev/null || echo "pending")

PG_HOST=$(az postgres flexible-server list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].fullyQualifiedDomainName" -o tsv 2>/dev/null || echo "—")

SQL_SERVER=$(az sql server list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].fullyQualifiedDomainName" -o tsv 2>/dev/null || echo "—")

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  VM + COMPUTE DEPLOYED"
echo "════════════════════════════════════════════════════════════════════"
echo "  VM Public IP:      $VM_IP"
echo "  SSH:               ssh familyadmin@$VM_IP"
echo "  PostgreSQL host:   $PG_HOST"
echo "  SQL Server:        $SQL_SERVER"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  NEXT STEPS"
echo "  1. Open SSH port if needed:"
echo "     az vm open-port --resource-group $RESOURCE_GROUP --name familyos-b1s-vm --port 22"
echo "  2. Store DB password in Key Vault:"
echo "     az keyvault secret set --vault-name willbracken-kv-<suffix> --name vm-admin-password --value '<pass>'"
echo "  3. Configure n8n PostgreSQL credentials with the host above"
echo "  4. Run bootstrap-n8n.sh from BrackenW3/n8n on the VM"
echo ""
