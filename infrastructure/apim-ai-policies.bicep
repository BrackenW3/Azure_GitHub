// =============================================================================
// apim-ai-policies.bicep — APIM AI Gateway API, operations, policy, named value
// Resource group: willbracken-free-rg
//
// Deploys onto the EXISTING APIM instance (willbracken-apim-ihe42a):
//   • API  — ai-gateway (path: /ai)
//   • Operations — POST /chat, POST /embed
//   • Inbound policy — model-based routing to Azure OpenAI, rate limiting, CORS
//   • Named value — aoai-key (secret, Key Vault reference)
//   • Role assignment — Key Vault Secrets User on APIM system identity → KV
//
// Prerequisites:
//   • managed-identities.bicep deployed
//   • always-free-extended.bicep deployed (APIM + Key Vault exist)
//   • azure-openai.bicep deployed — capture the endpoint output and store it
//     in Key Vault secret "azure-openai-key" before deploying this template.
//   • APIM system-assigned identity must be enabled on willbracken-apim-ihe42a.
//     Verify: az apim show -n willbracken-apim-ihe42a -g willbracken-free-rg \
//               --query "identity.type"
//
// Deploy:
//   az deployment group create \
//     --resource-group willbracken-free-rg \
//     --template-file apim-ai-policies.bicep \
//     --parameters aoaiEndpoint=<azure-openai.bicep output: endpoint>
//
// Notes:
//   • The APIM named value "aoai-key" is a Key Vault reference — the secret
//     "azure-openai-key" must exist in willbracken-kv-ihe42a before deploying.
//   • The inbound policy routes /chat requests to Azure OpenAI chat completions
//     and /embed requests to Azure OpenAI embeddings, using the aoai-key header.
//   • Rate limit: 100 calls / 60 s per subscription key.
//   • CORS: origins * — suitable for development only. Restrict before production.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region — must match the existing APIM instance location.')
param location string = 'eastus'

@description('Name of the existing APIM service instance.')
param apimServiceName string = 'willbracken-apim-ihe42a'

@description('Name of the existing Key Vault that holds the Azure OpenAI key secret.')
param keyVaultName string = 'willbracken-kv-ihe42a'

@description('Azure OpenAI endpoint URL — from azure-openai.bicep output: endpoint.')
param aoaiEndpoint string

@description('Display name shown in the APIM developer portal for the AI Gateway API.')
param apiDisplayName string = 'AI Gateway'

@description('Rate limit: maximum calls allowed per renewal period, per subscription key.')
param rateLimitCalls int = 100

@description('Rate limit renewal window in seconds.')
param rateLimitPeriod int = 60

// ── Key Vault Secrets User role definition ID (built-in) ─────────────────────
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

// ── Key Vault secret resource ID used as the named value source ───────────────
var aoaiKeySecretId = '/subscriptions/11301eb9-a26b-4b41-badb-c1b10f446d99/resourceGroups/willbracken-free-rg/providers/Microsoft.KeyVault/vaults/${keyVaultName}/secrets/azure-openai-key'

var tags = {
  Environment:  'Development'
  Project:      'WillBracken'
  BillingTier:  '12-Month-Free'
  AutoDestroy:  'ReviewAt11Months'
}

// ── Reference existing APIM instance ─────────────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2023-03-01-preview' existing = {
  name: apimServiceName
}

// ── Reference existing Key Vault ──────────────────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// ── Named Value: aoai-key (Key Vault reference, secret) ──────────────────────
// APIM retrieves the Azure OpenAI API key from Key Vault at policy evaluation time.
// The APIM system identity needs Key Vault Secrets User to read this secret.
resource aoaiKeyNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-03-01-preview' = {
  parent: apim
  name: 'aoai-key'
  properties: {
    displayName: 'aoai-key'
    secret: true    // Stored as a secret — not visible in portal UI or policy trace
    keyVault: {
      secretIdentifier: aoaiKeySecretId
    }
    tags: ['azure-openai', 'ai-gateway']
  }
}

// ── RBAC: APIM system identity → Key Vault Secrets User ──────────────────────
// Required for APIM to resolve the named value from Key Vault at runtime.
// Uses the APIM system-assigned identity (not a user-assigned identity).
resource apimKvSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, apim.id, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId:      apim.identity.principalId    // System-assigned identity principal
    principalType:    'ServicePrincipal'
    description:      'APIM system identity — read aoai-key from Key Vault'
  }
}

// ── AI Gateway API ────────────────────────────────────────────────────────────
// Exposes Azure OpenAI endpoints through APIM under the /ai path prefix.
resource aiGatewayApi 'Microsoft.ApiManagement/service/apis@2023-03-01-preview' = {
  parent: apim
  name: 'ai-gateway'
  properties: {
    displayName: apiDisplayName
    path: 'ai'
    protocols: ['https']
    subscriptionRequired: true    // Require APIM subscription key for all calls
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query:  'subscription-key'
    }
    apiType: 'http'
    isCurrent: true
    // serviceUrl is not set here — each operation policy sets the backend URL directly
  }
}

// ── Operation: POST /chat ─────────────────────────────────────────────────────
// Proxies chat completion requests to Azure OpenAI /openai/deployments/{model}/chat/completions.
// The request body must contain a "model" field (e.g., "gpt-4o" or "gpt-4o-mini").
resource chatOperation 'Microsoft.ApiManagement/service/apis/operations@2023-03-01-preview' = {
  parent: aiGatewayApi
  name: 'post-chat'
  properties: {
    displayName: 'Chat Completion'
    method: 'POST'
    urlTemplate: '/chat'
    description: 'Route a chat completion request to Azure OpenAI. Include "model" field in the JSON body to select the deployment (e.g., "gpt-4o" or "gpt-4o-mini").'
    request: {
      description: 'OpenAI-compatible chat completion request body'
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 200
        description: 'Successful chat completion response'
        representations: [
          { contentType: 'application/json' }
        ]
      }
      {
        statusCode: 429
        description: 'Rate limit exceeded'
      }
    ]
  }
}

// ── Operation: POST /embed ────────────────────────────────────────────────────
// Proxies embedding requests to Azure OpenAI /openai/deployments/text-embedding-3-small/embeddings.
resource embedOperation 'Microsoft.ApiManagement/service/apis/operations@2023-03-01-preview' = {
  parent: aiGatewayApi
  name: 'post-embed'
  properties: {
    displayName: 'Create Embeddings'
    method: 'POST'
    urlTemplate: '/embed'
    description: 'Generate embeddings via Azure OpenAI text-embedding-3-small deployment.'
    request: {
      description: 'OpenAI-compatible embeddings request body'
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 200
        description: 'Successful embeddings response'
        representations: [
          { contentType: 'application/json' }
        ]
      }
      {
        statusCode: 429
        description: 'Rate limit exceeded'
      }
    ]
  }
}

// ── API-level Inbound Policy ──────────────────────────────────────────────────
// Applied to all operations in the ai-gateway API.
// Route logic:
//   • POST /chat → Azure OpenAI chat completions, model selected from request body
//   • POST /embed → Azure OpenAI embeddings (text-embedding-3-small)
// Auth: api-key header sourced from named value aoai-key (Key Vault).
// CORS: allow-origins * — for development. Restrict before production.
//
// Strategy: the raw string template uses __AOAI_ENDPOINT__, __RATE_CALLS__,
// __RATE_PERIOD__ as placeholders. Bicep replace() calls substitute the actual
// param values before ARM receives the string. This avoids escaping conflicts
// between Bicep interpolation syntax and APIM policy C# expression syntax.
var policyTemplate = '''<policies>
  <inbound>
    <base />

    <!-- CORS: allow all origins for development.
         Replace * with specific origins before production. -->
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>POST</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>Content-Type</header>
        <header>Ocp-Apim-Subscription-Key</header>
      </allowed-headers>
    </cors>

    <!-- Rate limiting: __RATE_CALLS__ calls / __RATE_PERIOD__ s per subscription key -->
    <rate-limit-by-key calls="__RATE_CALLS__" renewal-period="__RATE_PERIOD__"
                       counter-key="@(context.Subscription.Key)"
                       increment-condition="@(true)"
                       retry-after-header-name="Retry-After"
                       remaining-calls-header-name="X-RateLimit-Remaining" />

    <!-- Inject Azure OpenAI API key from named value (Key Vault reference) -->
    <set-header name="api-key" exists-action="override">
      <value>{{aoai-key}}</value>
    </set-header>

    <!-- Remove APIM subscription key before forwarding to Azure OpenAI -->
    <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />

    <!-- Store the AOAI endpoint — value is baked in at deploy time by Bicep -->
    <set-variable name="aoaiEndpoint" value="__AOAI_ENDPOINT__" />

    <!-- Route /chat: extract model from request body, forward to AOAI chat completions.
         Supported model values: "gpt-4o" (default) or "gpt-4o-mini" -->
    <choose>
      <when condition="@(context.Operation.Name == &quot;post-chat&quot;)">
        <set-variable name="aoaiModel"
                      value="@{
                        try {
                          var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
                          var model = (string)body[&quot;model&quot;];
                          if (model == &quot;gpt-4o-mini&quot;) return &quot;gpt-4o-mini&quot;;
                          return &quot;gpt-4o&quot;;
                        } catch {
                          return &quot;gpt-4o&quot;;
                        }
                      }" />
        <set-backend-service
          base-url="@(string.Format(&quot;{0}openai/deployments/{1}/chat/completions&quot;, context.Variables[&quot;aoaiEndpoint&quot;], context.Variables[&quot;aoaiModel&quot;]))" />
        <set-query-parameter name="api-version" exists-action="override">
          <value>2024-02-01</value>
        </set-query-parameter>
      </when>

      <!-- Route /embed: forward to text-embedding-3-small -->
      <when condition="@(context.Operation.Name == &quot;post-embed&quot;)">
        <set-backend-service
          base-url="@(string.Format(&quot;{0}openai/deployments/text-embedding-3-small/embeddings&quot;, context.Variables[&quot;aoaiEndpoint&quot;]))" />
        <set-query-parameter name="api-version" exists-action="override">
          <value>2024-02-01</value>
        </set-query-parameter>
      </when>
    </choose>

    <!-- Enforce JSON content type -->
    <set-header name="Content-Type" exists-action="override">
      <value>application/json</value>
    </set-header>
  </inbound>

  <backend>
    <forward-request timeout="120" follow-redirects="false" buffer-request-body="true" />
  </backend>

  <outbound>
    <base />
    <!-- Strip internal Azure headers before returning to caller -->
    <set-header name="x-ms-request-id" exists-action="delete" />
    <set-header name="x-ms-region" exists-action="delete" />
  </outbound>

  <on-error>
    <base />
    <choose>
      <when condition="@(context.Response.StatusCode == 429)">
        <return-response>
          <set-status code="429" reason="Too Many Requests" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>{"error":"rate_limit_exceeded","message":"Rate limit reached. Check Retry-After header."}</set-body>
        </return-response>
      </when>
    </choose>
  </on-error>
</policies>'''

// Substitute param values into the policy template at ARM/Bicep evaluation time.
var policyXml = replace(
  replace(
    replace(policyTemplate, '__AOAI_ENDPOINT__', aoaiEndpoint),
    '__RATE_CALLS__', string(rateLimitCalls)
  ),
  '__RATE_PERIOD__', string(rateLimitPeriod)
)

resource aiGatewayPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-03-01-preview' = {
  parent: aiGatewayApi
  name: 'policy'
  dependsOn: [aoaiKeyNamedValue]    // Named value must exist before policy is evaluated
  properties: {
    format: 'xml'
    value: policyXml
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Resource ID of the deployed ai-gateway API')
output aiGatewayApiId string = aiGatewayApi.id

@description('API path prefix — base URL will be https://<apim-host>/ai')
output apiPath string = aiGatewayApi.properties.path

@description('Named value resource ID for aoai-key')
output aoaiKeyNamedValueId string = aoaiKeyNamedValue.id
