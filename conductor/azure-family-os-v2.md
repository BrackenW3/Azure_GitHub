# Azure & Family OS Implementation Plan (v2)

## 1. Background & Motivation
The goal is to implement a highly cost-optimized Azure architecture that maximizes the 12-month and always-free tiers, alongside a non-technical "Family OS" built on Jira, Confluence, and n8n. The immediate focus is resolving multi-tenant login issues, establishing a robust compute layer with App Services, integrating AI via Cloudflare and Microsoft Foundry, and building the required API connectors (Microsoft Graph) for n8n to manipulate Excel/Office files.

## 2. Scope & Impact
*   **Role Management:** Fix multi-tenant login confusion and explicitly set `william3bracken` to Owner and demote `willbracken33` to Contributor.
*   **Compute & Data:** Deploy free Linux App Services (Python 3.12 and Node 22 LTS) connected to Azure SQL and Cosmos DB. Connect these to GitHub CI/CD using Federated Credentials (OIDC).
*   **AI Integration:** Centralize AI API providers through Cloudflare AI Gateway, leveraging Microsoft Foundry Serverless Endpoints for a cost-effective, cached AI strategy.
*   **n8n Excel Connector:** Create a Microsoft Entra App Registration granting broad application access (`Files.ReadWrite.All`) to allow n8n to read and write Excel documents via the Microsoft Graph API.
*   **Atlassian SSO:** Set up Enterprise Application SSO for Jira/Confluence.

## 3. Proposed Solution
*   **RBAC Script:** Write a PowerShell command to remove `willbracken33`'s Owner role and explicitly assign the Contributor role.
*   **Graph API Script:** Develop `scripts/setup-graph-app.ps1`. This script will use the Azure CLI (`az ad app create`) to register an application, configure a client secret, assign the `Files.ReadWrite.All` Graph API permission, grant admin consent, and securely output the Client ID, Tenant ID, and Client Secret. These are the exact credentials n8n needs for the Microsoft Excel node.
*   **Azure Prepare Workflow:** In compliance with strict deployment mandates, we will generate the canonical `.azure/deployment-plan.md` in the workspace root, map the requested free-tier App Services and AI resources into infrastructure templates, and use `azure-validate` to confirm deployment readiness.

## 4. Alternatives Considered
*   **Kubernetes (AKS):** Deploying AKS on B2s VMs was considered but rejected due to the high operational maintenance required for a personal/family project, favoring fully managed App Services.
*   **Azure OpenAI:** Considered for AI workloads but rejected due to the lack of a free tier and lack of BYOK (Bring Your Own Key) support. The Cloudflare + Foundry approach provides better caching and cost control.
*   **Restricted Graph Access:** Considered limiting n8n to specific SharePoint sites, but opted for Broad Access (`Files.ReadWrite.All`) to simplify the initial setup and testing phase.

## 5. Implementation Plan
*   **Step 1:** Execute the role assignment updates via Azure CLI to fix login issues.
*   **Step 2:** Write and execute `scripts/setup-graph-app.ps1` to create the API connectors for Excel/Office.
*   **Step 3:** Scaffold `.azure/deployment-plan.md` in the workspace root per `azure-prepare` mandates.
*   **Step 4:** Ensure `app-services.bicep` and `ai-services.bicep` are aligned with the plan and ready for deployment.
*   **Step 5:** Provide instructions for configuring Atlassian SSO via Entra ID Enterprise Applications.

## 6. Verification
*   Run `az role assignment list` to confirm `willbracken33` is a Contributor.
*   Run `az ad app list` to confirm the n8n Graph App was created successfully.
*   Use the `azure-validate` skill to ensure the infrastructure is sound before invoking `azure-deploy`.

## 7. Migration & Rollback
*   If the role assignments cause lockout issues, the primary billing account can reinstate the Owner role.
*   The n8n Entra App can be deleted via `az ad app delete` if the secret is compromised or the connector is no longer needed.
