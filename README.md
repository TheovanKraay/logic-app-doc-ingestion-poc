# Logic App Standard — Document Ingestion to Azure Cosmos DB (vector search) with Managed Identity

Two samples that ingest documents (PDFs) from **Azure Blob Storage**, extract text with
**Azure AI Document Intelligence**, create embeddings with **Azure OpenAI**, and write the
chunks + vectors into **Azure Cosmos DB for NoSQL** where they can be queried with
**native vector search** — all wired with **Managed Identity** (no account keys, no SAS)
so it works even when the storage account has **shared key access disabled**.

## Quick deploy (full end-to-end sample)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FTheovanKraay%2Flogic-app-doc-ingestion-poc%2Fmain%2Ffull-deploy%2Fazuredeploy.json)

> **Note:** the button fetches the ARM template from `raw.githubusercontent.com`, which
> only works when the repository is **public**. While this repo is private, use
> `azd up` from [`full-deploy/`](full-deploy/) instead (or make the repo public).
> You will be asked for a location and your **Azure OpenAI endpoint** + embedding
> deployment name.

## Why this exists

Customers hardening their storage (shared key disabled / private endpoints) hit two classes of failure:

- **Data access**: key-based connections and key-signed **SAS tokens** are rejected
  (`403 KeyBasedAuthenticationNotPermitted`). The fix is **Managed Identity** (Entra ID + RBAC).
- **Logic App host storage**: on the **Workflow Standard** plan the runtime's Azure Files
  content share still requires shared key, so the app's *own* host storage account keeps
  shared key enabled. This is separate from your data and holds none of your documents.

Both samples apply that split: **your data = Managed Identity only**, the app's throwaway
host storage = the one account that keeps shared key.

## Samples

| Folder | What it does | Use when |
| --- | --- | --- |
| [`full-deploy/`](full-deploy/) | `azd up` provisions **everything**: blob + Cosmos (vector) + Logic App Standard + user-assigned managed identity + role assignments + the workflow. | You want a clean, self-contained demo from nothing. |
| [`bring-your-own/`](bring-your-own/) | `azd up` takes your **existing** Cosmos and Blob account names as parameters, creates the managed identity, assigns the data-plane roles on *your* resources, and deploys the workflow wired to MI. | You already have Cosmos + Blob and just want the pipeline wired up securely. |

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli)
- An Azure OpenAI resource with a text embedding deployment (e.g. `text-embedding-3-small`)
- An Azure AI Document Intelligence resource

## Security model

- Blob and Cosmos connections use **Managed Identity** (`Storage Blob Data Reader` and
  `Cosmos DB Built-in Data Contributor`). No keys or SAS in the workflow.
- If a component ever needs a URL, use an Entra-signed **user-delegation SAS**, not a key SAS.
- The Logic App host storage account is the only account that uses shared key, and only
  because the Workflow Standard content share requires it.

See each sample's README for step-by-step instructions.
