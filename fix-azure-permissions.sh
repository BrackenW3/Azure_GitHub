#!/usr/bin/env bash
# =============================================================================
# fix-azure-permissions.sh — az CLI version of the permissions fix
# Use this if you prefer Bash over PowerShell.
# Same actions as fix-azure-permissions.ps1
#
# Usage:
#   az login --tenant willbracken.com --use-device-code
#   bash fix-azure-permissions.sh
# =============================================================================

set -euo pipefail

TENANT_DOMAIN="willbracken.com"
ADMIN1="will@willbracken.com"
ADMIN2="security@willbracken.com"
DRY_RUN="${DRY_RUN:-false}"

log()  { echo ""; echo "▶  $*"; }
ok()   { echo "   ✓ $*"; }
warn() { echo "   ⚠  $*"; }
info() { echo "   → $*"; }
die()  { echo "✗ ERROR: $*" >&2; exit 1; }

# ── Auth check ────────────────────────────────────────────────────────────────
log "Checking Azure login..."
az account show &>/dev/null || {
    warn "Not logged in. Use:"
    warn "  az login --tenant $TENANT_DOMAIN --use-device-code"
    exit 1
}

TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
CURRENT_USER=$(az account show --query user.name -o tsv)

ok "Tenant:       $TENANT_ID"
ok "Subscription: $SUB_NAME ($SUB_ID)"
ok "Logged in as: $CURRENT_USER"

# ── Phase 1: Audit root scope ─────────────────────────────────────────────────
log "Checking root scope role assignments..."
ROOT_ROLES=$(az role assignment list --scope "/" --query "[].{user:principalName,role:roleDefinitionName}" -o tsv 2>/dev/null || echo "")
if [[ -n "$ROOT_ROLES" ]]; then
    warn "Root scope assignments found (REMOVE THESE):"
    echo "$ROOT_ROLES" | while read -r line; do warn "  $line"; done
else
    ok "No root scope role assignments found — root scope is clean"
fi

# ── Remove root scope EXT account elevation ───────────────────────────────────
log "Removing User Access Administrator from EXT/guest accounts at root scope..."
EXT_ROOT=$(az role assignment list --scope "/" \
    --query "[?contains(principalName,'#EXT#')].{id:id,user:principalName,role:roleDefinitionName}" \
    -o json 2>/dev/null || echo "[]")

COUNT=$(echo "$EXT_ROOT" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$COUNT" -gt 0 ]]; then
    echo "$EXT_ROOT" | python3 -c "
import sys, json
assignments = json.load(sys.stdin)
for a in assignments:
    print(a.get('id',''), a.get('user',''), a.get('role',''))
" | while read -r assignment_id user role; do
        warn "Found: $user | $role at /"
        if [[ "$DRY_RUN" != "true" ]]; then
            az role assignment delete --ids "$assignment_id" 2>/dev/null \
                && ok "Removed root scope role from $user" \
                || warn "Could not remove — may need portal (Entra ID Properties → toggle ON → remove → toggle OFF)"
        else
            ok "[DRY RUN] Would remove: $user | $role"
        fi
    done
else
    ok "No EXT accounts with root scope roles"
fi

# ── Phase 2: Check domain ─────────────────────────────────────────────────────
log "Checking custom domain: $TENANT_DOMAIN..."
DOMAIN_STATUS=$(az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/domains/$TENANT_DOMAIN" \
    --query "isVerified" -o tsv 2>/dev/null || echo "unknown")

if [[ "$DOMAIN_STATUS" == "true" ]]; then
    ok "Domain $TENANT_DOMAIN is verified"
else
    warn "Domain $TENANT_DOMAIN is NOT verified or not found"
    info "Fix: Entra ID → Custom domain names → Add/Verify $TENANT_DOMAIN"
    info "Add TXT record to Cloudflare DNS, then click Verify in portal"
fi

# ── Phase 3: Create/check native admin users ──────────────────────────────────
log "Checking native admin accounts..."

for EMAIL in "$ADMIN1" "$ADMIN2"; do
    info "Processing: $EMAIL"

    USER_TYPE=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/users/$EMAIL" \
        --query "userType" -o tsv 2>/dev/null || echo "NotFound")

    case "$USER_TYPE" in
        "Member")
            ok "$EMAIL — native Member ✓"
            ;;
        "Guest")
            warn "$EMAIL exists as GUEST — needs conversion to Member in portal"
            info "  Entra ID → Users → $EMAIL → Edit properties → User type: Member"
            ;;
        "NotFound"|"")
            warn "$EMAIL not found — creating native member account..."
            TEMP_PASS="Temp$(shuf -i 10000-99999 -n1)!Az"
            NICK="${EMAIL%%@*}"

            if [[ "$DRY_RUN" != "true" ]]; then
                az ad user create \
                    --display-name "${NICK^}" \
                    --user-principal-name "$EMAIL" \
                    --password "$TEMP_PASS" \
                    --force-change-password-next-sign-in true \
                    2>/dev/null && ok "Created: $EMAIL (temp password: $TEMP_PASS)" \
                    || warn "Could not create $EMAIL — domain may not be verified yet"
            else
                ok "[DRY RUN] Would create native user: $EMAIL (temp: $TEMP_PASS)"
            fi
            ;;
    esac
done

# ── Phase 4: Assign Global Administrator ─────────────────────────────────────
log "Assigning Global Administrator role..."
GLOBAL_ADMIN_TEMPLATE="62e90394-69f5-4237-9190-012177145e10"

for EMAIL in "$ADMIN1" "$ADMIN2"; do
    # Get user object ID
    USER_ID=$(az ad user show --id "$EMAIL" --query id -o tsv 2>/dev/null || echo "")

    if [[ -z "$USER_ID" ]]; then
        warn "Cannot assign Global Admin to $EMAIL — user not found (create first)"
        continue
    fi

    # Check if already in role
    ALREADY=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$GLOBAL_ADMIN_TEMPLATE/members" \
        --query "value[?userPrincipalName=='$EMAIL'].id" -o tsv 2>/dev/null || echo "")

    if [[ -n "$ALREADY" ]]; then
        ok "$EMAIL is already Global Administrator"
    else
        if [[ "$DRY_RUN" != "true" ]]; then
            az rest --method POST \
                --url "https://graph.microsoft.com/v1.0/directoryRoles/roleTemplateId=$GLOBAL_ADMIN_TEMPLATE/members/\$ref" \
                --body "{\"@odata.id\": \"https://graph.microsoft.com/v1.0/directoryObjects/$USER_ID\"}" \
                2>/dev/null && ok "Assigned Global Administrator to $EMAIL" \
                || warn "Failed to assign role to $EMAIL (may already have it via another path)"
        else
            ok "[DRY RUN] Would assign Global Administrator to $EMAIL"
        fi
    fi
done

# ── Phase 5: Remove EXT accounts from subscription roles ─────────────────────
log "Cleaning up guest/EXT account roles at subscription scope..."

GUEST_ROLES=$(az role assignment list --subscription "$SUB_ID" \
    --query "[?contains(principalName,'#EXT#')].{id:id,user:principalName,role:roleDefinitionName}" \
    -o json 2>/dev/null || echo "[]")

GUEST_COUNT=$(echo "$GUEST_ROLES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$GUEST_COUNT" -gt 0 ]]; then
    warn "$GUEST_COUNT guest accounts have subscription roles"
    echo "$GUEST_ROLES" | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(a.get('id',''), a.get('user',''), a.get('role',''))
" | while read -r assign_id user role; do
        warn "  $user | $role"
        if [[ "$role" =~ ^(Owner|Contributor|User.Access.Administrator)$ ]]; then
            if [[ "$DRY_RUN" != "true" ]]; then
                az role assignment delete --ids "$assign_id" 2>/dev/null \
                    && ok "  Removed privileged role from $user" \
                    || warn "  Could not remove — check in portal"
            else
                ok "  [DRY RUN] Would remove $role from $user"
            fi
        fi
    done
else
    ok "No guest accounts with subscription roles"
fi

# ── Phase 6: Fix user consent (ChatGPT/OpenAI) ───────────────────────────────
log "Fixing user consent settings (fixes ChatGPT/OpenAI 'needs admin approval')..."

if [[ "$DRY_RUN" != "true" ]]; then
    az rest --method PATCH \
        --url "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" \
        --body '{
            "defaultUserRolePermissions": {
                "permissionGrantPoliciesAssigned": [
                    "ManagePermissionGrantsForSelf.microsoft-user-default-legacy"
                ]
            }
        }' 2>/dev/null && ok "User consent policy updated — verified apps no longer need admin approval" \
        || warn "Could not update consent policy — do it in portal:"
    info "  Entra ID → Enterprise Apps → Consent and permissions → User consent settings"
    info "  → Allow user consent for apps from verified publishers"
else
    ok "[DRY RUN] Would update user consent policy"
fi

# ── Phase 7: Create service principals ───────────────────────────────────────
log "Creating service principals..."

for SP_CONFIG in "claude-mcp-sp:Contributor" "n8n-automation-sp:Reader"; do
    SP_NAME="${SP_CONFIG%%:*}"
    SP_ROLE="${SP_CONFIG##*:}"

    EXISTING=$(az ad sp list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")
    if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
        ok "$SP_NAME already exists (appId: $EXISTING)"
    else
        if [[ "$DRY_RUN" != "true" ]]; then
            SP_JSON=$(az ad sp create-for-rbac \
                --name "$SP_NAME" \
                --role "$SP_ROLE" \
                --scopes "/subscriptions/$SUB_ID" \
                -o json 2>/dev/null)

            if [[ -n "$SP_JSON" ]]; then
                echo "$SP_JSON" | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
print(f'  appId:  {d[\"appId\"]}')
print(f'  tenant: {d[\"tenant\"]}')
print(f'  secret: {d[\"password\"]}')
" && ok "$SP_NAME created"
            fi
        else
            ok "[DRY RUN] Would create SP: $SP_NAME with $SP_ROLE on subscription"
        fi
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  DONE"
echo "════════════════════════════════════════════════════════════════════"
echo "  Next steps:"
echo "  1. Sign in to portal.azure.com as will@willbracken.com"
echo "  2. Change temp password"
echo "  3. Paste claude-mcp-sp credentials to Claude to enable Azure MCP"
echo "  4. Run: az login --tenant $TENANT_DOMAIN --use-device-code"
echo "════════════════════════════════════════════════════════════════════"
