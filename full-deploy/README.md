# Full deploy — step-by-step portal walkthrough

This guide takes you from nothing to a working pipeline: **drop a PDF in Blob Storage →
OCR with Document Intelligence → embeddings with Azure OpenAI → vectors stored in Azure
Cosmos DB for NoSQL (native vector search)** — with your data accessed via **Managed
Identity** (no keys/SAS), even when the storage account has shared key disabled.

There is **no Azure AI Search** anywhere; search is Cosmos DB's built-in vector search.

---

## What gets deployed

| Resource | Purpose | Auth to it |
| --- | --- | --- |
| User-assigned managed identity (`*-mi`) | Identity the workflow uses for data | — |
| Data storage (`*data`) + `documents` container | Holds your PDFs | **Managed identity** (shared key OFF) |
| Host storage (`*host`) | Logic App runtime/content share | Shared key ON (app-owned, no customer data) |
| Cosmos DB (`*-cosmos`), db `rag`, container `documents` | Vector store (1536-dim, DiskANN) | **Managed identity** (key auth OFF) |
| Azure OpenAI (`*-aoai`) + `text-embedding-3-small` | Embeddings | **Key** (this connector has no MI option) |
| Document Intelligence (`*-docint`) | OCR | **Managed identity** (key auth OFF) |
| Workflow Standard plan + Logic App (`*-logic`) | Runs the workflow | — |

> `*` is a per-deployment prefix, e.g. `laiufzdgv5235zp4`.

---

## Prerequisites

- An Azure subscription and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
- Your own **object ID** (to upload PDFs): `az ad signed-in-user show --query id -o tsv`

---

## Step 1 — Deploy the infrastructure

Use the **Deploy to Azure** button in the [root README](../README.md), or run `azd up`
from this folder. When prompted:

- **environmentName** – any short name (used as a prefix).
- **location** – your region (e.g. `eastus2`).
- **openAiLocation** – a region with `text-embedding-3-small` quota (defaults to `location`).
- **deployerPrincipalId** – **paste your object ID** (from the prereq). This grants you
  `Storage Blob Data Contributor` so you can upload PDFs in the portal. If you skip it,
  you'll get *"You do not have permissions to list the data"* and must assign the role
  manually later.

Set a shell variable to your resource group for the commands below:

```powershell
$RG = "rg-<environmentName>"   # e.g. rg-tvktest
```

---

## Step 2 — Collect the values you'll paste into the portal

```powershell
# Managed identity resource ID (for Blob + Cosmos connections)
az identity list -g $RG --query "[?ends_with(name,'-mi')].id | [0]" -o tsv

# Blob endpoint
az storage account show -g $RG -n (az storage account list -g $RG --query "[?ends_with(name,'data')].name|[0]" -o tsv) --query primaryEndpoints.blob -o tsv

# Azure OpenAI endpoint + name
az cognitiveservices account list -g $RG --query "[?kind=='OpenAI'].{name:name,endpoint:properties.endpoint}" -o table

# Document Intelligence endpoint
az cognitiveservices account show -g $RG -n (az cognitiveservices account list -g $RG --query "[?kind=='FormRecognizer'].name|[0]" -o tsv) --query properties.endpoint -o tsv

# Cosmos account / db / container
az cosmosdb list -g $RG --query "[].name" -o tsv    # db = rag, container = documents
```

---

## Step 3 — One-time auth prep (two quirks)

Two connectors don't fit the "managed identity everywhere" default, so prepare them once:

**a) Azure OpenAI — enable key auth** (its built-in connector supports **only** key or
AD-OAuth, not managed identity):

```powershell
$AOAI = az cognitiveservices account list -g $RG --query "[?kind=='OpenAI'].name|[0]" -o tsv
az resource update -g $RG -n $AOAI --resource-type "Microsoft.CognitiveServices/accounts" --set properties.disableLocalAuth=false -o none
```

**b) Document Intelligence — give the Logic App a system-assigned identity + role**
(its connection uses *Logic Apps Managed Identity*, i.e. the **system-assigned** identity):

```powershell
$LA = az resource list -g $RG --resource-type Microsoft.Web/sites --query "[0].name" -o tsv
$PID = az webapp identity assign -g $RG -n $LA --query principalId -o tsv
$DOCINT = az cognitiveservices account list -g $RG --query "[?kind=='FormRecognizer'].name|[0]" -o tsv
$DID = az cognitiveservices account show -g $RG -n $DOCINT --query id -o tsv
az role assignment create --assignee-object-id $PID --assignee-principal-type ServicePrincipal --role "Cognitive Services User" --scope $DID -o none
```

> The user-assigned identity already has: `Storage Blob Data Reader` (data storage),
> `Cosmos DB Built-in Data Contributor` (Cosmos), and `Cognitive Services OpenAI User`
> (OpenAI). Role changes can take a few minutes to propagate.

---

## Step 4 — Upload PDFs

Portal: open the **data** storage account → **Storage browser → Blob containers →
documents → Upload**. (Authentication method resolves to *Microsoft Entra ID* — no key.)

Or CLI:

```powershell
$DATA = az storage account list -g $RG --query "[?ends_with(name,'data')].name|[0]" -o tsv
az storage blob upload --account-name $DATA --container-name documents --name myfile.pdf --file .\myfile.pdf --auth-mode login --overwrite
```

---

## Step 5 — Create the workflow from the template

1. Open the **Logic App** (`*-logic`) → **Workflows → Add → Add from template** (or
   **Templates**), and choose **"Document ingestion from Azure Blob Storage using Azure
   Document Intelligence into Azure Cosmos DB"**.
2. On **Basics**, give the workflow a name (e.g. `cdb-doc-indexer-blob`), **Stateful**.

---

## Step 6 — Wire the four connections (this is the important part)

Create each connection with the auth type below. **Do not** leave any on Access Key /
"Microsoft Entra ID Integrated" (that signs in as *you*, not the app).

### Azure Blob Storage → **Managed identity**
| Field | Value |
| --- | --- |
| Authentication Type | **Managed identity** |
| Managed Identity | **UserAssigned** |
| User Managed Identity Resource ID | the `*-mi` resource ID (Step 2) |
| Storage Account Endpoint String | `https://<prefix>data.blob.core.windows.net` |

### Azure Cosmos DB → **Managed identity**
| Field | Value |
| --- | --- |
| Authentication Type | **Managed identity** / Logic Apps Managed Identity |
| Managed Identity | **UserAssigned** (the `*-mi` resource ID) |
| Account | `<prefix>-cosmos` (or its endpoint) |

### Azure OpenAI → **URL and key-based authentication**
*(this connector has no Managed identity option — that's why Step 3a enabled key auth)*
| Field | Value |
| --- | --- |
| Authentication Type | **URL and key-based authentication** |
| Azure OpenAI Endpoint URL | `https://<prefix>-aoai.openai.azure.com/` |
| Authentication Key | **KEY 1** from the AOAI resource → *Keys and Endpoint* |

### Azure AI Document Intelligence → **Logic Apps Managed Identity**
*(uses the app's system-assigned identity from Step 3b)*
| Field | Value |
| --- | --- |
| Authentication Type | **Logic Apps Managed Identity** |
| Endpoint URL | `https://<prefix>-docint.cognitiveservices.azure.com/` |

---

## Step 7 — Set the parameters

| Parameter | Value |
| --- | --- |
| OpenAI embedding deployment | `text-embedding-3-small` |
| Blob Storage documents path | `documents` &nbsp;← **container name only** (not a URL/expression) |
| Azure Cosmos DB account | `<prefix>-cosmos` |
| Azure Cosmos DB database | `rag` |
| Azure Cosmos DB collection | `documents` |
| Vector embeddings property | `embedding` &nbsp;← a **property name**, not a number |
| Document text property | `text` |

Then **Review + create**.

---

## Step 8 — Run it (and re-run it)

This is a **blob-triggered** workflow, so it runs on a blob event — **not** the manual
**Run** button (a manual run has no blob, so `blobName` is empty → `BadRequest /
ServiceOperationRequiredParameterMissing`).

- **New document:** upload a PDF to the `documents` container. The trigger polls (~30–60s)
  and fires automatically — one run per blob.
- **Re-run an existing document without uploading:** **Run history → pick a Succeeded run
  → Resubmit.** This replays with the original blob's trigger data.

---

## Step 9 — Verify

- **Run history** (left menu) shows each run and every action's inputs/outputs.
- **Cosmos DB**: open the `rag` / `documents` container → **Items**, or query:
  `SELECT VALUE COUNT(1) FROM c` and
  `SELECT TOP 3 c.documentName, c.chunkNumber, IS_DEFINED(c.embedding) AS hasVec FROM c`.
  Each chunk has a 1536-dim `embedding` in the DiskANN-indexed field, ready for vector search.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| *"You do not have permissions to list the data"* in Storage browser | Shared key is off, so the portal uses your Entra identity — you need `Storage Blob Data Contributor` on the data account. Set **deployerPrincipalId** at deploy, or assign it after. Allow a few minutes to propagate. |
| **"ReactView frame failed to load"** in the designer | Cosmetic portal issue. Click **Leave preview** for the classic designer, allow third-party cookies for `[*.]azure.com`, try InPrivate/another browser. The workflow still runs. |
| Read blob content: **`InvalidResourceName / The specified resource name contains invalid characters`** | The **Blob Storage documents path** was a URL or expression. It must be the plain container name, e.g. `documents`. |
| Read blob content: **`blobName is missing`** on a manual run | You used **Run** on a blob-triggered workflow. Upload a blob or **Resubmit** a previous run instead. |
| OpenAI connection won't authenticate | The account still has key auth disabled — run Step 3a. |
| Document Intelligence connection fails at runtime | The app's **system-assigned** identity or its `Cognitive Services User` role is missing/propagating — run Step 3b and wait a few minutes. |
