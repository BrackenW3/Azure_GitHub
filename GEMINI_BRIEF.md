# Gemini Agent Brief — willbracken.com Platform

**Copy this entire file into your Gemini conversation to get up to speed.**

---

## Who You Are Working For

Will Bracken (will@willbracken.com). Building a personal + small-team automation platform at willbracken.com. You are one of two AI agents working in parallel lanes — Claude handles Azure/Jira/Office, you handle Google/GCP/data. Will is the single decision-maker.

**Full architecture doc (Confluence):**
https://willbracken.atlassian.net/wiki/spaces/DS/pages/688129

---

## Hard Budget Rules

- $10–15/month total ongoing. Hard ceiling $30/month.
- Always-free tiers first. 12-month free second (with exit plans). Paid only when ROI is proven.
- Azure has $200 credits expiring in ~30 days — Claude is managing that lab. Your GCP work should stay in always-free.

---

## Current Stack (Already Running — Don't Rebuild These)

| Service | What It Does | Cost |
|---|---|---|
| n8n on Railway | All workflow automation | ~$5/mo |
| Neo4j on Railway | Knowledge graph | included |
| Supabase | Postgres + pgvector + auth | free |
| Cloudflare Workers | Edge APIs | free |
| Cloudflare R2 | Email body storage (10GB) | free |
| Cloudflare Vectorize | Email semantic search (30M dims/mo) | free |
| Cloudflare KV / D1 | KV store / SQLite edge | free |
| Jira + Confluence | Project tracking + wiki | existing |
| GitHub | Code + Actions CI/CD | free |

---

## Your Lane — GCP Free Tier to Activate

Activate ALL of these. They're always-free and never expire.

| Service | Free Tier | Use For |
|---|---|---|
| Cloud Functions (2nd gen) | 2M invocations/mo | Serverless triggers, integrations |
| Cloud Run | 2M req/mo, 180K vCPU-s | Container workloads |
| BigQuery | 1TB queries/mo + 10GB storage | Analytics, email trends, Jira metrics |
| Firestore | 1GB, 50K reads/day, 20K writes/day | Real-time state, lightweight NoSQL |
| Cloud Storage | 5GB US regional | File staging, export storage |
| Pub/Sub | 10GB/mo | Event streaming |
| Artifact Registry | 0.5GB | Container images |
| Secret Manager | 6 active secrets | Store API keys securely |
| Gemini API (Flash) | Free tier | Draft/classify tasks |

**Most immediately useful:** BigQuery for analytics + Gemini Flash for email classification.

---

## Build Priorities — Your Tasks

### Phase 1 (This Week)
1. **GCP Project setup** — Create project `willbracken-platform`, enable all free-tier APIs listed above
2. **BigQuery baseline** — Create dataset `platform_analytics`, tables: `email_metrics`, `jira_metrics`, `weekly_summary`
3. **Service account** — Create `n8n-gcp@willbracken-platform.iam.gserviceaccount.com` with BigQuery Data Editor + Cloud Run Invoker roles. Export JSON key → give to Will for n8n credentials.

### Phase 2 (Week 2)
4. **Gmail API integration** — OAuth2 for Will's Gmail. Cloud Function to sync Gmail → BigQuery (parallel to Armstrong IMAP pipeline)
5. **Gemini Flash email classifier** — Cloud Function: receives email text → returns `{category, action_required, priority, suggested_jira_title}`. Compare quality vs deterministic spam scorer already in n8n.
6. **Google Drive integration** — Cool-tier email body storage (emails 2–5 years old go to Drive, free 15GB)

### Phase 3 (Weeks 3–4)
7. **BigQuery → Neo4j sync** — Batch job: query BigQuery email metrics → push aggregated stats to Neo4j on Railway
8. **Vertex AI embeddings** — Test Vertex AI text-embedding-004 vs Cloudflare bge-base-en-v1.5 for email search quality. Winner stays.
9. **Weekly digest Cloud Function** — Runs Monday 8am, queries BigQuery → formats digest → posts to Confluence page (Platform Home)

---

## Key Integration Points (Where You Connect to Claude's Work)

- **Neo4j on Railway** — Both agents write here. Claude writes email+Jira nodes. You write analytics aggregations. Connection string: ask Will for Railway Neo4j credentials.
- **Supabase Postgres** — Shared database. Email metadata table: `public.emails`. You can query, don't write to it (Claude's n8n workflows own writes).
- **n8n webhooks** — Your Cloud Functions can POST to n8n webhook URLs to trigger workflows. Will provide URLs once n8n is configured.
- **Confluence** — Both agents write here. Use space DS (id: 294917). Claude owns Platform Home + Agent Handoff. You own GCP setup docs + BigQuery schema docs.
- **Jira KAN project** — Claude creates issues. You can add comments via API if needed.

---

## Email Pipeline (Already Built by Claude — Don't Rebuild)

The email pipeline is complete in n8n:
- **Realtime**: IMAP poll every 5min → normalize → spam score → R2 storage → CF Vectorize
- **Batch**: Historical backlog, 50 emails/6hrs, 30-day windows
- **Schema**: Supabase `public.emails` table with spam_score, vectorized, task_extracted flags

**Your job:** Build the AI classification layer ON TOP of this pipeline.
- Email task candidates come from Supabase view `email_task_candidates`
- Your Cloud Function gets a batch of candidates → classifies → updates `task_extracted = true` + `jira_issue_key`
- This runs after Claude's ingestion pipeline, not instead of it

---

## DuckDB Pattern (Reusable)

`ms-teams-export` project uses DuckDB + Express for analytical queries on structured data. The pattern: DuckDB + file storage = free data warehouse. Apply this to email analytics before reaching for BigQuery if the data volume is small (<1GB). BigQuery is better once you're querying across months of data.

---

## What Claude Is Handling (Don't Duplicate)

- Azure infrastructure (Bicep IaC, Cosmos DB, Functions, Container Apps)
- Jira board setup and Confluence wiki structure
- n8n workflow orchestration (email ingestion, MSGraph, task capture)
- Cloudflare Workers, R2, Vectorize, KV
- MSGraph / Office integration (Excel, Word, Outlook)

---

## Files and Code

All code is in `BrackenW3/n8n` repo, branch `claude/strange-villani`.
Key path: `C:\Users\User\WSL_Docker\n8n\.claude\worktrees\strange-villani\`

Your output files should go in:
- `workers/agent-gemini/` — Cloudflare Worker stubs already exist there
- `scripts/` — shell scripts for GCP setup
- `workflows/` — n8n workflow JSON files

---

## Credentials You'll Need from Will

1. GCP project credentials (after you create the project, generate service account key)
2. Railway Neo4j connection string (bolt://... + username + password)
3. Supabase connection string (already in n8n, Will can share)
4. n8n base URL (https://n8n.willbracken.com)

---

*Handoff doc generated by Claude. Last updated: 2026-04-12.*
*Questions about architecture → check Confluence page above or ask Will.*
