// server.js -- AI Router for Azure Container Apps
//
// Routes POST /chat based on model prefix:
//   claude-*              -> Anthropic API  (ANTHROPIC_API_KEY)
//   gpt-*                 -> OpenAI API     (OPENAI_API_KEY)
//   gemini-*              -> Google Gemini  (GEMINI_API_KEY)
//   mistral-* codestral-* -> Mistral API    (MISTRAL_API_KEY)
//
// Secrets: env var first, then Azure Key Vault via DefaultAzureCredential.
// Default model: claude-3-5-haiku-20241022
//
// GET  /health  -> {"status":"ok","version":"1.0.0"}
// GET  /metrics -> in-memory request counters
// POST /chat    -> normalized {model, content, usage:{input_tokens,output_tokens}}

import express from 'express';
import fetch from 'node-fetch';
import { DefaultAzureCredential } from '@azure/identity';
import { SecretClient } from '@azure/keyvault-secrets';

const app = express();
app.use(express.json());

const PORT    = process.env.PORT || 3000;
const VERSION = '1.0.0';
const KV_NAME = process.env.KEY_VAULT_NAME || 'willbracken-kv-ihe42a';
const KV_URI  = `https://${KV_NAME}.vault.azure.net`;

// -- In-memory metrics --------------------------------------------------------
const metrics = {
  total: 0,
  byProvider: { anthropic: 0, openai: 0, gemini: 0, mistral: 0 },
  errors: 0,
  startTime: new Date().toISOString(),
};

// -- Key Vault secret cache ---------------------------------------------------
let kvClient = null;
const secretCache = {};

function getKvClient() {
  if (!kvClient) {
    kvClient = new SecretClient(KV_URI, new DefaultAzureCredential());
  }
  return kvClient;
}

async function getSecret(envVar, kvSecretName) {
  if (process.env[envVar]) return process.env[envVar];
  if (secretCache[kvSecretName]) return secretCache[kvSecretName];
  try {
    const secret = await getKvClient().getSecret(kvSecretName);
    secretCache[kvSecretName] = secret.value;
    return secret.value;
  } catch (err) {
    console.warn(`[kv] Could not fetch secret "${kvSecretName}": ${err.message}`);
    return null;
  }
}

// -- Provider: Anthropic ------------------------------------------------------
async function callAnthropic(model, messages, maxTokens) {
  const apiKey = await getSecret('ANTHROPIC_API_KEY', 'anthropic-api-key');
  if (!apiKey) throw Object.assign(new Error('ANTHROPIC_API_KEY not configured'), { status: 500 });

  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens || 1024 }),
  });
  if (!res.ok) throw Object.assign(new Error(`Anthropic ${res.status}: ${await res.text()}`), { status: res.status });
  const d = await res.json();
  return {
    model: d.model,
    content: d.content?.[0]?.text ?? '',
    usage: { input_tokens: d.usage?.input_tokens ?? 0, output_tokens: d.usage?.output_tokens ?? 0 },
  };
}

// -- Provider: OpenAI ---------------------------------------------------------
async function callOpenAI(model, messages, maxTokens) {
  const apiKey = await getSecret('OPENAI_API_KEY', 'openai-api-key');
  if (!apiKey) throw Object.assign(new Error('OPENAI_API_KEY not configured'), { status: 500 });

  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens || 1024 }),
  });
  if (!res.ok) throw Object.assign(new Error(`OpenAI ${res.status}: ${await res.text()}`), { status: res.status });
  const d = await res.json();
  return {
    model: d.model,
    content: d.choices?.[0]?.message?.content ?? '',
    usage: { input_tokens: d.usage?.prompt_tokens ?? 0, output_tokens: d.usage?.completion_tokens ?? 0 },
  };
}

// -- Provider: Google Gemini --------------------------------------------------
async function callGemini(model, messages, maxTokens) {
  const apiKey = await getSecret('GEMINI_API_KEY', 'gemini-api-key');
  if (!apiKey) throw Object.assign(new Error('GEMINI_API_KEY not configured'), { status: 500 });

  const contents = messages.map(m => ({
    role: m.role === 'assistant' ? 'model' : 'user',
    parts: [{ text: m.content }],
  }));
  const geminiModel = model.startsWith('models/') ? model : `models/${model}`;
  const url = `https://generativelanguage.googleapis.com/v1beta/${geminiModel}:generateContent?key=${apiKey}`;

  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ contents, generationConfig: { maxOutputTokens: maxTokens || 1024 } }),
  });
  if (!res.ok) throw Object.assign(new Error(`Gemini ${res.status}: ${await res.text()}`), { status: res.status });
  const d = await res.json();
  return {
    model,
    content: d.candidates?.[0]?.content?.parts?.[0]?.text ?? '',
    usage: {
      input_tokens:  d.usageMetadata?.promptTokenCount     ?? 0,
      output_tokens: d.usageMetadata?.candidatesTokenCount ?? 0,
    },
  };
}

// -- Provider: Mistral --------------------------------------------------------
async function callMistral(model, messages, maxTokens) {
  const apiKey = await getSecret('MISTRAL_API_KEY', 'mistral-api-key');
  if (!apiKey) throw Object.assign(new Error('MISTRAL_API_KEY not configured'), { status: 500 });

  const res = await fetch('https://api.mistral.ai/v1/chat/completions', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens || 1024 }),
  });
  if (!res.ok) throw Object.assign(new Error(`Mistral ${res.status}: ${await res.text()}`), { status: res.status });
  const d = await res.json();
  return {
    model: d.model,
    content: d.choices?.[0]?.message?.content ?? '',
    usage: { input_tokens: d.usage?.prompt_tokens ?? 0, output_tokens: d.usage?.completion_tokens ?? 0 },
  };
}

// -- Routing ------------------------------------------------------------------
function resolveProvider(model) {
  if (!model) return 'anthropic';
  if (model.startsWith('claude-'))                                    return 'anthropic';
  if (model.startsWith('gpt-'))                                       return 'openai';
  if (model.startsWith('gemini-'))                                    return 'gemini';
  if (model.startsWith('mistral-') || model.startsWith('codestral-')) return 'mistral';
  return null;
}

// -- Express routes -----------------------------------------------------------
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', version: VERSION });
});

app.get('/metrics', (_req, res) => {
  res.json({
    ...metrics,
    uptimeSeconds: Math.floor((Date.now() - new Date(metrics.startTime)) / 1000),
  });
});

app.post('/chat', async (req, res) => {
  const { model: rawModel, messages, max_tokens } = req.body ?? {};

  if (!messages || !Array.isArray(messages) || messages.length === 0) {
    return res.status(400).json({ error: 'messages array is required' });
  }

  const model    = rawModel || 'claude-3-5-haiku-20241022';
  const provider = resolveProvider(model);

  if (!provider) {
    return res.status(400).json({
      error: `Unknown model prefix for "${model}". Supported: claude-, gpt-, gemini-, mistral-, codestral-`,
    });
  }

  metrics.total++;
  metrics.byProvider[provider] = (metrics.byProvider[provider] ?? 0) + 1;

  try {
    let result;
    switch (provider) {
      case 'anthropic': result = await callAnthropic(model, messages, max_tokens); break;
      case 'openai':    result = await callOpenAI(model, messages, max_tokens);    break;
      case 'gemini':    result = await callGemini(model, messages, max_tokens);    break;
      case 'mistral':   result = await callMistral(model, messages, max_tokens);   break;
    }
    res.json(result);
  } catch (err) {
    metrics.errors++;
    console.error(`[chat] ${provider} error:`, err.message);
    res.status(err.status ?? 502).json({ error: err.message });
  }
});

app.use((_req, res) => {
  res.status(404).json({ error: 'Not found. Available: GET /health, GET /metrics, POST /chat' });
});

// -- Start --------------------------------------------------------------------
app.listen(PORT, () => {
  console.log(`[ai-router] v${VERSION} listening on port ${PORT}`);
  console.log(`[ai-router] Key Vault: ${KV_URI}`);
  console.log(`[ai-router] Env keys -- ANTHROPIC:${!!process.env.ANTHROPIC_API_KEY} OPENAI:${!!process.env.OPENAI_API_KEY} GEMINI:${!!process.env.GEMINI_API_KEY} MISTRAL:${!!process.env.MISTRAL_API_KEY}`);
});
