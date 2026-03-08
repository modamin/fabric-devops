# Fabric Connection Management — CI/CD Pipeline

> **Purpose:** This document explains the end-to-end DevOps automation that deploys Microsoft Fabric workspaces across environments (DEV → UAT → PROD), solves the ID-remapping problem, and automatically creates and binds SQL connections for Semantic Models.

---

## Table of Contents

1. [The Problem This Solves](#1-the-problem-this-solves)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Tools & Libraries](#3-tools--libraries)
4. [Authentication](#4-authentication)
5. [Pipeline Overview](#5-pipeline-overview)
6. [Stage-by-Stage Walkthrough](#6-stage-by-stage-walkthrough)
7. [Key Configuration Files](#7-key-configuration-files)
8. [Repository Structure](#8-repository-structure)
9. [How to Run](#9-how-to-run)
10. [Prerequisites](#10-prerequisites)

---

## 1. The Problem This Solves

Deploying Microsoft Fabric workspaces across environments introduces two hard challenges:

### Challenge 1: IDs change between environments

Every Fabric artifact (Lakehouse, Semantic Model, Notebook, etc.) has a unique GUID that is different in every workspace. When you deploy a Semantic Model from DEV to UAT, any hardcoded DEV GUIDs embedded inside the artifact definition (e.g., in a connection string, data source reference, or expression) will be wrong in UAT.

```
DEV Lakehouse ID:  f926c5dc-1362-4de5-9d37-ca29c1be3d98
UAT Lakehouse ID:  a91b3e12-7f40-48cc-b102-d4e8f3ac0021  ← different!
```

### Challenge 2: SQL Connections don't exist in the target environment

Semantic Models that query a Lakehouse via SQL need a **Fabric Connection** object — a named, reusable connection that stores the SQL endpoint server/database and credentials. These connections:

- Don't exist in a brand-new UAT/PROD workspace
- Must be created **after** the Lakehouse is deployed (the SQL endpoint is only known post-deployment)
- Must be **bound** to the Semantic Model before the model is deployed

### The Solution

This pipeline handles both problems fully automatically in a 5-stage orchestration:

1. Capture all DEV artifact IDs → generate a substitution map (`parameter.yml`)
2. Deploy all artifacts, substituting DEV IDs → UAT IDs on the fly
3. Run the initialization notebook to seed data
4. Create SQL connections pointing to UAT Lakehouse SQL endpoints
5. Redeploy Semantic Models with the new connection bindings applied

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Azure DevOps Pipeline                            │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐              │
│  │  Stage 1     │    │  Stage 2     │    │  Stage 3     │              │
│  │  Capture     │───▶│  Deploy All  │───▶│  Initialize  │              │
│  │  Artifact IDs│    │  Artifacts   │    │  Data        │              │
│  └──────────────┘    └──────────────┘    └──────┬───────┘              │
│                                                  │                      │
│                         ┌────────────────────────▼─────────────┐       │
│                         │  Stage 4: Create SM Connections       │       │
│                         │  (Create SQL connections in UAT/PROD) │       │
│                         └────────────────────────┬─────────────┘       │
│                                                  │                      │
│                         ┌────────────────────────▼─────────────┐       │
│                         │  Stage 5: Deploy Semantic Models      │       │
│                         │  (With connection bindings applied)   │       │
│                         └──────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘

    DEV Workspace                           UAT / PROD Workspace
┌─────────────────┐                     ┌─────────────────────────┐
│  Lakehouse      │  Stage 1: read IDs  │  Lakehouse              │
│  Semantic Model │─────────────────▶   │  Semantic Model         │
│  Notebook       │  Stage 2: deploy ▶  │  Notebook               │
│  Report         │                     │  Report                 │
│  Dataflow       │                     │  Dataflow               │
└─────────────────┘                     │  SQL Connection (new)   │
                                        └─────────────────────────┘
```

---

## 3. Tools & Libraries

The pipeline uses four distinct tools, each serving a different purpose:

### `fabric-cicd` (Python library)
**PyPI:** `fabric-cicd`
**What it does:** Handles deploying Fabric workspace items (Lakehouses, Notebooks, Semantic Models, Reports, etc.) from a Git repository into a target workspace. It reads the item definitions stored in the repository and calls the Fabric REST API to create or update them.

**Key capability — parameterization:** `fabric-cicd` reads `parameter.yml` and performs find-and-replace on artifact content at deploy time, swapping DEV GUIDs for UAT GUIDs using dynamic token expressions like `$items.Lakehouse.conn_mgmt_lh.$id`.

```python
from fabric_cicd import FabricWorkspace, publish_all_items, unpublish_all_orphan_items

target_workspace = FabricWorkspace(
    workspace_id=args.workspace_id,
    environment=args.environment,
    repository_directory=repository_directory,
    item_type_in_scope=item_type_in_scope,
    token_credential=token_credential,
)

publish_all_items(fabric_workspace_obj=target_workspace)
unpublish_all_orphan_items(target_workspace)  # cleans up items removed from repo
```

---

### `ms-fabric-cli` (CLI tool — `fab`)
**PyPI:** `ms-fabric-cli`
**What it does:** A command-line tool that wraps the Fabric REST API, letting scripts interact with workspaces, lakehouses, notebooks, and connections using simple commands rather than raw HTTP calls.

**Key commands used in this pipeline:**

| Command | Purpose |
|---------|---------|
| `fab ls <workspace>.Workspace -l --output_format json` | List all items in a workspace |
| `fab get <workspace>.Workspace/<item>.Lakehouse -q 'properties.sqlEndpointProperties.connectionString'` | Query the SQL endpoint of a Lakehouse |
| `fab get <workspace>.Workspace -q 'id'` | Get a workspace's GUID |
| `fab exists .connections/<name>.Connection` | Check if a connection already exists |
| `fab create .connections/<name>.Connection -P <params>` | Create a new connection |
| `fab auth login -u <clientId> --federated-token <token> --tenant <tenantId>` | Authenticate using a federated token |
| `fab api -X post connections/<id>/roleAssignments` | Grant access to a connection |

---

### Fabric REST API (direct HTTP calls)
**Base URL:** `https://api.fabric.microsoft.com/v1`
**What it does:** Used directly (via `Invoke-WebRequest`) to trigger notebook runs and poll for completion — a capability not yet exposed in the Fabric CLI.

```powershell
# Trigger notebook run
POST /v1/workspaces/{workspaceId}/items/{notebookId}/jobs/instances?jobType=RunNotebook

# Poll job status (URL returned in Location header of the 202 response)
GET <Location URL>
```

---

### Azure CLI (`az`)
**What it does:** Used for authentication. The Azure DevOps service connection logs into Azure via the `AzureCLI@2` pipeline task, making an authenticated `az` session available to all scripts. Scripts then use this session to:

- Get bearer tokens for the Fabric REST API (`az account get-access-token`)
- Get tenant and client IDs to authenticate the Fabric CLI (`az account show`)

---

## 4. Authentication

Authentication is layered — each tool uses a different mechanism, all rooted in the same Azure DevOps service connection.

```
Azure DevOps Service Connection (Service Principal)
        │
        ▼
AzureCLI@2 task  ──────────────────────────────────────────────┐
        │                                                       │
        ▼                                                       │
az login (automatic, via task)                                  │
        │                                                       │
        ├──▶  AzureCliCredential()  ──▶  fabric-cicd           │
        │     (Python SDK)               calls Fabric REST API  │
        │                                                       │
        ├──▶  az account get-access-token  ──▶  Fabric REST API│
        │     Bearer token                    (notebook trigger)│
        │                                                       │
        └──▶  az account show + $env:idToken                   │
              Federated token  ──▶  fab auth login  ──▶  fab CLI│
```

### `fabric-cicd` Authentication

Uses `AzureCliCredential` from the `azure-identity` Python SDK. This automatically picks up the `az` session established by the `AzureCLI@2` task — no explicit credentials needed in the script.

```python
from azure.identity import AzureCliCredential

token_credential = AzureCliCredential()

target_workspace = FabricWorkspace(
    workspace_id=args.workspace_id,
    token_credential=token_credential,   # ← uses the az session
    ...
)
```

### Fabric CLI Authentication

Uses a **federated OIDC token** issued by Azure DevOps. The `AzureCLI@2` task exposes this token in the `$env:idToken` environment variable when `addSpnToEnvironment: true` is set.

```powershell
# install_fab_cli.ps1
$tenantId = az account show --query tenantId -o tsv
$clientId = az account show --query user.name -o tsv

fab auth login -u $clientId --federated-token $env:idToken --tenant $tenantId
```

This approach is preferred over a client secret because:
- No secrets need to be stored in pipeline variables
- The token is short-lived and scoped to the pipeline run
- Federated identity is the recommended pattern for Azure DevOps workload identity

### Fabric REST API Authentication (Notebook runner)

Acquires a bearer token scoped specifically to the Fabric API:

```powershell
# run_notebook.ps1
$accessToken = az account get-access-token `
    --resource "https://api.fabric.microsoft.com" `
    --query accessToken -o tsv

$headers = @{ "Authorization" = "Bearer $accessToken" }
```

### Connection Creation Credentials

When creating a new SQL connection, the service principal's credentials are passed as connection parameters. These are stored as Azure DevOps secret variables and injected as environment variables:

```powershell
# create_sm_connection.ps1 (New-FabricConnection)
$params = @(
    "credentialDetails.type=ServicePrincipal",
    "credentialDetails.tenantId=$env:FAB_TENANT_ID",
    "credentialDetails.servicePrincipalClientId=$env:FAB_CLIENT_ID",
    "credentialDetails.servicePrincipalSecret=$env:FAB_CLIENT_SECRET",
    ...
) -join ","

fab create $connectionPath -P $params
```

---

## 5. Pipeline Overview

The pipeline is defined in [azure-pipelines.yml](azure-pipelines.yml) and triggered manually with parameters.

### Pipeline Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `environment` | Target environment: DEV, UAT, or PROD | `UAT` |
| `workspaceId` | GUID of the target Fabric workspace | *(UAT workspace ID)* |
| `devWorkspaceName` | Name of the DEV workspace to read IDs from | `cicd-conn-mgmt-dev` |
| `uatWorkspaceName` | Name of the target workspace | `cicd-conn-mgmt-uat` |
| `groupId` | AAD Group ID to grant Owner access on connections | *(group ID)* |
| `userIds` | Comma-separated AAD User Object IDs for access grants | *(user IDs)* |
| `initNotebookName` | Name of the notebook to run for data initialization | `conn_mgmt_init_nb` |
| `deployMode` | `full` or `connections-only` | `full` |

### Deploy Modes

| Mode | Stages Run | When to Use |
|------|-----------|-------------|
| `full` | All 5 stages | Full deployment — first time or after artifact changes |
| `connections-only` | Stages 4 & 5 only | Recreate/repair connections without redeploying artifacts |

### Azure DevOps Variables (set in pipeline settings, not in YAML)

| Variable | Description |
|----------|-------------|
| `azureServiceConnection` | Name of the Azure service connection |
| `FAB_CLIENT_ID` | Service principal app ID (for connection credentials) |
| `FAB_CLIENT_SECRET` | Service principal secret *(secret variable)* |
| `FAB_TENANT_ID` | Azure AD tenant ID |

---

## 6. Stage-by-Stage Walkthrough

### Stage 1 — Capture Artifact IDs

**Script:** [.deploy/capture_artifact_ids.ps1](.deploy/capture_artifact_ids.ps1)
**Runs on:** DEV workspace
**Condition:** `deployMode == 'full'`

**What it does:**

The DEV workspace has all the "source of truth" artifact IDs. This stage reads them out and creates a substitution map so `fabric-cicd` can replace DEV IDs with target environment IDs at deploy time.

**Process flow:**

```
1. fab ls <devWorkspace>.Workspace -l --output_format json
        │
        ▼
2. Filter to data object types:
   Lakehouse, Warehouse, Eventhouse, KQLDatabase,
   MirroredDatabase, SQLDatabase
        │
        ▼
3. For each Lakehouse:
   fab get <workspace>/<name>.Lakehouse
   → extract SQL endpoint: connectionString + id
        │
        ▼
4. Write artifact_mapping.json (pipeline artifact)
        │
        ▼
5. Build parameter.yml with find_replace entries:
   DEV workspace ID   → $workspace.$id
   DEV lakehouse ID   → $items.Lakehouse.<name>.$id
   DEV SQL endpoint ID → $items.Lakehouse.<name>.$sqlendpointid
   DEV SQL conn string → $items.Lakehouse.<name>.$sqlendpoint
        │
        ▼
6. Publish parameter.yml as pipeline artifact
```

**Example generated `parameter.yml`:**

```yaml
find_replace:
  - find_value: e0a0c0d0-c9d9-4a7e-978d-6ac8e79af581      # DEV workspace ID
    replace_value:
      _ALL_: $workspace.$id                                 # → UAT workspace ID

  - find_value: f926c5dc-1362-4de5-9d37-ca29c1be3d98       # DEV lakehouse ID
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$id              # → UAT lakehouse ID

  - find_value: 5c6d4df6-6984-45c3-b51b-d979fdcc62d9       # DEV SQL endpoint ID
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$sqlendpointid

  - find_value: ABC123XY.datawarehouse.fabric.microsoft.com # DEV SQL conn string
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$sqlendpoint
```

> `_ALL_` means the substitution applies to all environments. `fabric-cicd` resolves the `$items.*` and `$workspace.*` tokens to the actual UAT/PROD values when deploying.

---

### Stage 2 — Deploy All Artifacts

**Script:** [.deploy/deploy_fabric.py](.deploy/deploy_fabric.py)
**Runs on:** Target workspace (UAT/PROD)
**Condition:** `deployMode == 'full'`
**Depends on:** Stage 1

**What it does:**

Downloads the `parameter.yml` artifact from Stage 1, then uses `fabric-cicd` to deploy every artifact type from the repository into the target workspace.

**Process flow:**

```
1. Download parameter.yml from Stage 1 pipeline artifact
        │
        ▼
2. pip install fabric-cicd
        │
        ▼
3. python .deploy/deploy_fabric.py
   --workspace-id <UAT workspace ID>
   --environment UAT
        │
        ▼
4. fabric-cicd reads repo, reads parameter.yml
   For each artifact in repo:
     - Replace DEV IDs with UAT IDs (find_replace)
     - Create or update the item in the target workspace
        │
        ▼
5. unpublish_all_orphan_items()
   Removes artifacts in the workspace that no longer exist in the repo
```

**Supported artifact types:**

`Lakehouse`, `Warehouse`, `Eventhouse`, `KQLDatabase`, `MirroredDatabase`, `SQLDatabase`, `SemanticModel`, `Notebook`, `DataPipeline`, `Report`, `KQLQueryset`, `Environment`, `Reflex`, `Eventstream`, `CopyJob`, `VariableLibrary`, `Dataflow`

**Feature flags enabled:**

| Flag | Purpose |
|------|---------|
| `enable_exclude_folder` | Skips folders matching `EXCLUDE.*` pattern |
| `enable_lakehouse_unpublish` | Allows lakehouses to be removed as orphans |
| `enable_experimental_features` | Enables preview capabilities in `fabric-cicd` |

---

### Stage 3 — Initialize Data

**Script:** [.deploy/run_notebook.ps1](.deploy/run_notebook.ps1)
**Runs on:** Target workspace (UAT/PROD)
**Condition:** Previous stage did not fail
**Depends on:** Stage 2

**What it does:**

Runs a Fabric Notebook in the target workspace to seed or initialize data (e.g., creating tables, loading reference data). This runs **after** deployment so the Lakehouse structure is in place.

**Process flow:**

```
1. fab get <workspace>.Workspace -q 'id'
   → resolve workspace GUID
        │
        ▼
2. fab get <workspace>.Workspace/<notebook>.Notebook -q 'id'
   → resolve notebook GUID
        │
        ▼
3. az account get-access-token --resource https://api.fabric.microsoft.com
   → acquire Bearer token
        │
        ▼
4. POST /v1/workspaces/{workspaceId}/items/{notebookId}/jobs/instances?jobType=RunNotebook
   → trigger async notebook run
   → read Location header from 202 response
        │
        ▼
5. Poll Location URL every 30 seconds (max 60 minutes)
   until status is: Completed | Failed | Cancelled | Deduped
        │
        ▼
6. Fail the pipeline stage if status ≠ Completed
```

---

### Stage 4 — Create Semantic Model Connections

**Scripts:** [.deploy/create_sm_connections_stage.ps1](.deploy/create_sm_connections_stage.ps1), [.deploy/create_sm_connection.ps1](.deploy/create_sm_connection.ps1)
**Runs on:** Target workspace (UAT/PROD)
**Condition:** Previous stage did not fail
**Depends on:** Stage 3

**What it does:**

This is the most complex stage. Semantic Models that query a Lakehouse need a **Fabric SQL Connection** object — a persistent, reusable connection that stores the SQL server endpoint and credentials. Those connections can only be created after the Lakehouse exists in the target environment.

**Process flow:**

```
1. Read connection_mapping.json
   (defines: connection_name, semantic_model_name, lakehouse_name)
        │
        ▼
2. For each entry in connection_mapping.json:
        │
        ├─ Get SQL endpoint from target workspace:
        │    fab get <workspace>/<lakehouse>.Lakehouse
        │    → connectionString (SQL server hostname)
        │    → id (SQL database ID)
        │
        ├─ Check if connection already exists:
        │    fab exists .connections/<name>.Connection
        │
        ├─ If not exists → create connection:
        │    fab create .connections/<name>.Connection -P <params>
        │    (type=SQL, ServicePrincipal credentials)
        │
        ├─ Grant Owner access to AAD Group:
        │    fab api -X post connections/<id>/roleAssignments
        │    { "principal": { "id": "<groupId>", "type": "Group" }, "role": "Owner" }
        │
        └─ Grant Owner access to individual Users (if specified):
             fab api -X post connections/<id>/roleAssignments
             { "principal": { "id": "<userId>", "type": "User" }, "role": "Owner" }
        │
        ▼
3. Build semantic_model_binding entries:
   [ { connection_id: "<id>", semantic_model_name: "conn_mgmt_sm" } ]
        │
        ▼
4. Append semantic_model_binding to parameter.yml
   (preserves existing find_replace entries)
        │
        ▼
5. Publish updated parameter.yml as pipeline artifact 'parameter_yml_with_bindings'
```

**Example `parameter.yml` after Stage 4:**

```yaml
find_replace:
  - find_value: f926c5dc-1362-4de5-9d37-ca29c1be3d98
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$id
  # ... (other find_replace entries from Stage 1)

semantic_model_binding:
  - connection_id: 7a3c1f88-bd42-4e19-9cd1-0f8a2e3b5d71
    semantic_model_name: conn_mgmt_sm
```

> The `semantic_model_binding` section tells `fabric-cicd` to bind the Semantic Model to the given connection ID when deploying it.

---

### Stage 5 — Deploy Semantic Models

**Script:** [.deploy/deploy_fabric.py](.deploy/deploy_fabric.py) (with `--items SemanticModel`)
**Runs on:** Target workspace (UAT/PROD)
**Condition:** Previous stage did not fail
**Depends on:** Stage 4

**What it does:**

Runs `deploy_fabric.py` a second time, but this time targeted only at Semantic Models and using the updated `parameter.yml` that now includes the `semantic_model_binding` section. This final deployment binds each Semantic Model to its SQL connection.

```
1. Download parameter_yml_with_bindings artifact
        │
        ▼
2. python .deploy/deploy_fabric.py
   --workspace-id <UAT workspace ID>
   --environment UAT
   --items SemanticModel
        │
        ▼
3. fabric-cicd deploys Semantic Models
   Uses semantic_model_binding from parameter.yml
   to bind each model to its SQL connection
```

---

## 7. Key Configuration Files

### `connection_mapping.json`

Defines which Semantic Models need SQL connections and which Lakehouses they connect to. Add one entry per Semantic Model that queries a Lakehouse via DirectLake or SQL.

```json
[
  {
    "connection_name": "my-connection-1939",
    "semantic_model_name": "conn_mgmt_sm",
    "lakehouse_name": "conn_mgmt_lh"
  }
]
```

| Field | Description |
|-------|-------------|
| `connection_name` | The display name of the Fabric SQL Connection to create |
| `semantic_model_name` | The Semantic Model to bind the connection to |
| `lakehouse_name` | The Lakehouse whose SQL endpoint the connection points to |

Multiple entries are supported — one per Semantic Model / Lakehouse pair.

---

### `parameter.yml`

**Auto-generated by the pipeline — do not edit manually.**

This file is built fresh in Stage 1 and extended in Stage 4. It drives all environment-specific substitutions inside `fabric-cicd`.

**Two sections:**

| Section | Set By | Purpose |
|---------|--------|---------|
| `find_replace` | Stage 1 | Replaces DEV GUIDs with UAT/PROD GUIDs in artifact definitions |
| `semantic_model_binding` | Stage 4 | Binds each Semantic Model to its SQL connection ID |

**Token syntax used in `find_replace`:**

| Token | Resolves To |
|-------|------------|
| `$workspace.$id` | The target workspace's GUID |
| `$items.Lakehouse.<name>.$id` | The target Lakehouse's GUID |
| `$items.Lakehouse.<name>.$sqlendpointid` | The target Lakehouse's SQL endpoint GUID |
| `$items.Lakehouse.<name>.$sqlendpoint` | The target Lakehouse's SQL server hostname |

---

### `azure-pipelines.yml`

Defines the pipeline stages, their order, conditions, and parameters. Key design decisions:

- Each stage runs on a fresh `windows-latest` agent
- Stages pass data to each other via **pipeline artifacts** (not environment variables), making them durable across agent boundaries
- `deployMode: connections-only` skips Stages 1–3, jumping directly to connection creation and Semantic Model redeployment — useful for fixing connection issues without a full redeploy

---

## 8. Repository Structure

```
fabric_workspace_root_directory/
│
├── azure-pipelines.yml              # Pipeline definition (all 5 stages)
├── connection_mapping.json          # Defines SM → Lakehouse connection mappings
├── parameter.yml                    # Auto-generated by pipeline (do not edit)
│
├── .deploy/                         # All deployment automation scripts
│   ├── capture_artifact_ids.ps1     # Stage 1: reads DEV IDs, generates parameter.yml
│   ├── deploy_fabric.py             # Stages 2 & 5: deploys artifacts via fabric-cicd
│   ├── install_fab_cli.ps1          # Installs ms-fabric-cli and authenticates
│   ├── run_notebook.ps1             # Stage 3: triggers notebook and polls for completion
│   ├── create_sm_connections_stage.ps1  # Stage 4 orchestrator: reads mapping, calls helpers
│   └── create_sm_connection.ps1    # Stage 4 functions: Get-LakehouseSqlEndpoint,
│                                   #   New-FabricConnection, Grant-FabricConnectionAccess
│
├── my_lakehouse.Lakehouse/          # Lakehouse artifact definition
├── my_semantic_model.SemanticModel/      # Semantic Model artifact definition
├── my_notebook.Notebook/           # Notebook artifact definition
├── my_report.Report/             # Report artifact definition
└── my_dataflow.Dataflow/           # Dataflow artifact definition
```

> Fabric artifact folders follow the naming convention `<name>.<Type>/`. The `fabric-cicd` library uses this convention to discover and deploy items.

---

## 9. How to Run

### Add devops artifacts
1. In your Fabric git repository, add the files in .deploy, azure-pipelines.yml, connection_mapping.json, and parameter.yml, as shown in step 8. 
2. Create a new Azure DevOps pipeline using azure-pipelines.yml
3. Configure service-connection as an input variable to the Azure DevOps pipeline



### Run the Full Pipeline

Trigger the pipeline in Azure DevOps with the default parameters. This runs all 5 stages:

```
deployMode: full
environment: UAT
workspaceId: <UAT workspace GUID>
devWorkspaceName: cicd-conn-mgmt-dev
uatWorkspaceName: cicd-conn-mgmt-uat
groupId: <AAD group GUID>
initNotebookName: conn_mgmt_init_nb
```

### Recreate Connections Only (no full redeploy)

Use `connections-only` mode to fix or recreate connections without touching other artifacts:

```
deployMode: connections-only
environment: UAT
workspaceId: <UAT workspace GUID>
uatWorkspaceName: cicd-conn-mgmt-uat
groupId: <AAD group GUID>
```

### Run Deployment Script Locally

Requires `az login` first, then:

```bash
# Install dependency
pip install fabric-cicd

# Deploy everything
python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT

# Deploy only Semantic Models
python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT \
  --items SemanticModel

# Deploy multiple specific types
python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT \
  --items SemanticModel Notebook Report
```

---

## 10. Prerequisites

### Azure DevOps

- An Azure DevOps pipeline connected to this repository
- An **Azure service connection** (service principal) with:
  - Contributor or Member access to the target Fabric workspace
  - Permissions to create Fabric connections (Fabric tenant settings)
- Pipeline variables configured:
  - `azureServiceConnection` — the service connection name
  - `FAB_CLIENT_ID` — service principal app ID
  - `FAB_CLIENT_SECRET` — service principal secret *(mark as secret)*
  - `FAB_TENANT_ID` — Azure AD tenant ID

### Fabric Workspace

- DEV and UAT/PROD workspaces provisioned
- Fabric items checked into this repository from the DEV workspace
- Service principal added as a Member or Admin on both workspaces

### Runtime (installed automatically by pipeline)

| Tool | Version | Install |
|------|---------|---------|
| Python | 3.11+ | `UsePythonVersion@0` task |
| `fabric-cicd` | latest | `pip install fabric-cicd` |
| `ms-fabric-cli` | latest | `pip install ms-fabric-cli` |
| `powershell-yaml` | latest | `Install-Module powershell-yaml` |
