# Fabric Connection Management — CI/CD Pipeline

> **Purpose:** This document explains the end-to-end DevOps automation that deploys Microsoft Fabric workspaces across environments (DEV → UAT → PROD) using a trunk-based branching model with project-based folder filtering, solves the ID-remapping problem, and automatically creates and binds SQL connections for Semantic Models.

---

## Table of Contents

1. [Branching Model](#1-branching-model)
2. [The Problem This Solves](#2-the-problem-this-solves)
3. [High-Level Architecture](#3-high-level-architecture)
4. [Tools & Libraries](#4-tools--libraries)
5. [Authentication](#5-authentication)
6. [Pipeline Overview](#6-pipeline-overview)
7. [Stage-by-Stage Walkthrough](#7-stage-by-stage-walkthrough)
8. [Key Configuration Files](#8-key-configuration-files)
9. [Repository Structure](#9-repository-structure)
10. [How to Run](#10-how-to-run)
11. [Prerequisites](#11-prerequisites)

---

## 1. Branching Model

This repository follows **trunk-based development (Option 4)** for Fabric CI/CD with **project-based folder filtering**.

### Branch Strategy

| Branch | Purpose | Deployment |
|--------|---------|------------|
| `main` | Integration branch | Synced to **dev** workspace via **Update from GIT** (no pipeline runs) |
| `uat/<project>/x.y` | Release candidate | Deploys only `<project>` folder to **UAT** workspace via `fabric-cicd` |
| `prod/<project>/x.y` | Production release | Deploys only `<project>` folder to **PROD** workspace via `fabric-cicd` |

### Release Workflow

```
main (dev workspace — synced via "Update from GIT")
  │
  ├── Create Branch ──▶ uat/conn_mgmt/1.0 ──▶ fabric-cicd ──▶ UAT workspace (conn_mgmt folder only)
  │                          │
  │                     Create Branch ──▶ prod/conn_mgmt/1.0 ──▶ fabric-cicd ──▶ Prod workspace
  │
  ├── Create Branch ──▶ uat/conn_mgmt/1.1 ──▶ fabric-cicd ──▶ UAT workspace (conn_mgmt folder only)
  │                          │
  │                     Create Branch ──▶ prod/conn_mgmt/1.1 ──▶ fabric-cicd ──▶ Prod workspace
  │
  ├── Create Branch ──▶ uat/other_project/1.0 ──▶ fabric-cicd ──▶ UAT workspace (other_project folder only)
  │
  └── ...
```

### Project-Based Filtering

The branch name encodes which project to deploy:

```
uat/<project_name>/<version>
     └─────┬─────┘
           │
           ▼
  folder_path_to_include = ["/<project_name>"]
```

- The pipeline extracts `<project_name>` from the branch (2nd segment)
- Only items inside the `/<project_name>/` workspace folder are deployed
- Items in other folders or at the root are **not** deployed
- This allows multiple teams/projects to share a single repository and workspace

### Release History

| UAT Branches | Prod Branches |
|--------------|---------------|
| `uat/conn_mgmt/1.0` | `prod/conn_mgmt/1.0` |
| `uat/conn_mgmt/1.1` | `prod/conn_mgmt/1.1` |
| `uat/other_project/1.0` | `prod/other_project/1.0` |

### Key Principles

- **No long-lived branches** for UAT and PROD — each release creates new short-lived branches
- **main** is always the source of truth — developers commit to main, which syncs to the dev workspace
- **Environment is auto-detected** from the branch prefix (`uat/*` or `prod/*`)
- **Project is auto-detected** from the branch name (2nd segment)
- **Pipeline rejects runs from main** — the dev workspace is managed entirely via "Update from GIT"
- **Branch must have 3 segments** — `env/project/version` format is validated

---

## 2. The Problem This Solves

Deploying Microsoft Fabric workspaces across environments introduces two hard challenges:

### Challenge 1: IDs change between environments

Every Fabric artifact (Lakehouse, Semantic Model, Notebook, etc.) has a unique GUID that is different in every workspace. When you deploy a Semantic Model from DEV to UAT, any hardcoded DEV GUIDs embedded inside the artifact definition will be wrong in UAT.

```
DEV Lakehouse ID:  f926c5dc-1362-4de5-9d37-ca29c1be3d98
UAT Lakehouse ID:  a91b3e12-7f40-48cc-b102-d4e8f3ac0021  ← different!
```

### Challenge 2: SQL Connections don't exist in the target environment

Semantic Models that query a Lakehouse via SQL need a **Fabric Connection** object. These connections:

- Don't exist in a brand-new UAT/PROD workspace
- Must be created **after** the Lakehouse is deployed (the SQL endpoint is only known post-deployment)
- Must be **bound** to the Semantic Model before the model is deployed

### Challenge 3: Multi-project repository

Multiple projects share the same repository and workspace. Deploying everything on every release is wasteful and risky — you only want to deploy the items that belong to the project being released.

### The Solution

This pipeline handles all three problems fully automatically in a 5-stage orchestration:

1. Capture all DEV artifact IDs → generate a substitution map (`parameter.yml`)
2. Deploy only the project's folder items, substituting DEV IDs → UAT/PROD IDs on the fly
3. Run the initialization notebook to seed data
4. Create SQL connections pointing to target Lakehouse SQL endpoints
5. Redeploy Semantic Models with the new connection bindings applied

---

## 3. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Azure DevOps Pipeline                            │
│  Branch: uat/conn_mgmt/1.0 → env=UAT, project=conn_mgmt               │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐              │
│  │  Stage 1     │    │  Stage 2     │    │  Stage 3     │              │
│  │  Capture     │───▶│  Deploy All  │───▶│  Initialize  │              │
│  │  Artifact IDs│    │  (project    │    │  Data        │              │
│  │              │    │   folder)    │    │              │              │
│  └──────────────┘    └──────────────┘    └──────┬───────┘              │
│                                                  │                      │
│                         ┌────────────────────────▼─────────────┐       │
│                         │  Stage 4: Create SM Connections       │       │
│                         │  (Create SQL connections in target)   │       │
│                         └────────────────────────┬─────────────┘       │
│                                                  │                      │
│                         ┌────────────────────────▼─────────────┐       │
│                         │  Stage 5: Deploy Semantic Models      │       │
│                         │  (project folder, with bindings)      │       │
│                         └──────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘

    DEV Workspace                           UAT / PROD Workspace
┌─────────────────┐                     ┌─────────────────────────┐
│  /conn_mgmt/    │                     │  /conn_mgmt/            │
│    Lakehouse    │  Stage 1: read IDs  │    Lakehouse            │
│    Semantic M.  │─────────────────▶   │    Semantic Model       │
│    Notebook     │  Stage 2: deploy ▶  │    Notebook             │
│    Report       │  (folder only)      │    Report               │
│    Dataflow     │                     │    Dataflow             │
│                 │                     │    SQL Connection (new)  │
│  /other_proj/   │                     │                         │
│    ...          │  ← NOT deployed     │  /other_proj/           │
└─────────────────┘                     │    (untouched)          │
                                        └─────────────────────────┘
```

---

## 4. Tools & Libraries

### `fabric-cicd` (Python library)
**PyPI:** `fabric-cicd`
**What it does:** Deploys Fabric workspace items from a Git repository into a target workspace. Reads item definitions and calls the Fabric REST API to create or update them.

**Key capabilities:**
- **Parameterization:** Reads `parameter.yml` and performs find-and-replace on artifact content at deploy time
- **Folder-level include:** `folder_path_to_include` parameter deploys only items within specified workspace folders
- **Semantic model binding:** Binds Semantic Models to SQL connections using the `semantic_model_binding` section in `parameter.yml`

```python
from fabric_cicd import FabricWorkspace, publish_all_items, unpublish_all_orphan_items

target_workspace = FabricWorkspace(
    workspace_id=args.workspace_id,
    environment=args.environment,
    repository_directory=repository_directory,
    item_type_in_scope=item_type_in_scope,
    token_credential=token_credential,
)

publish_all_items(
    fabric_workspace_obj=target_workspace,
    folder_path_to_include=["/conn_mgmt"],  # Only deploy this project's folder
)
unpublish_all_orphan_items(target_workspace)
```

---

### `ms-fabric-cli` (CLI tool — `fab`)
**PyPI:** `ms-fabric-cli`
**What it does:** Wraps the Fabric REST API for scripted interactions with workspaces, lakehouses, notebooks, and connections.

**Key commands used:**

| Command | Purpose |
|---------|---------|
| `fab ls <workspace>.Workspace -l --output_format json` | List all items in a workspace |
| `fab get <workspace>.Workspace/<item>.Lakehouse -q 'properties.sqlEndpointProperties.connectionString'` | Query Lakehouse SQL endpoint |
| `fab exists .connections/<name>.Connection` | Check if a connection exists |
| `fab create .connections/<name>.Connection -P <params>` | Create a new connection |
| `fab api -X post connections/<id>/roleAssignments` | Grant access to a connection |

---

### Fabric REST API (direct HTTP)
**Base URL:** `https://api.fabric.microsoft.com/v1`
**Used for:** Triggering notebook runs and polling for completion (not yet exposed in Fabric CLI).

---

### Azure CLI (`az`)
**Used for:** Authentication — getting bearer tokens, tenant/client IDs for the Fabric CLI.

---

## 5. Authentication

All authentication flows from a single Azure DevOps service connection:

```
Azure DevOps Service Connection (Service Principal)
        │
        ▼
AzureCLI@2 task
        │
        ├──▶  AzureCliCredential()  ──▶  fabric-cicd
        │
        ├──▶  az account get-access-token  ──▶  Fabric REST API (notebook trigger)
        │
        └──▶  Federated token ($env:idToken)  ──▶  fab auth login  ──▶  fab CLI
```

---

## 6. Pipeline Overview

The pipeline is defined in [azure-pipelines.yml](azure-pipelines.yml) and triggered manually.

### Branch-to-Environment Mapping

| Branch Pattern | Environment | Variable Group |
|----------------|-------------|----------------|
| `uat/<project>/*` | UAT | `fabric-uat` |
| `prod/<project>/*` | PROD | `fabric-prod` |
| `main` | *(rejected)* | — |

### Pipeline Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `devWorkspaceName` | Name of the DEV workspace to read IDs from | `cicd-conn-mgmt-dev` |
| `initNotebookName` | Name of the notebook to run for data initialization | `conn_mgmt_init_nb` |
| `deployMode` | `full` or `connections-only` | `full` |

### Variable Groups (configured in Azure DevOps)

Each environment requires a variable group with these variables:

| Variable | Description |
|----------|-------------|
| `targetWorkspaceId` | GUID of the target Fabric workspace |
| `targetWorkspaceName` | Display name of the target Fabric workspace |
| `groupId` | AAD Group ID to grant Owner access on SQL connections |
| `userIds` | Comma-separated AAD User Object IDs for connection access |
| `azureServiceConnection` | Name of the Azure service connection |

- **`fabric-uat`** — for `uat/*` branches
- **`fabric-prod`** — for `prod/*` branches

### Deploy Modes

| Mode | Stages Run | When to Use |
|------|-----------|-------------|
| `full` | All 5 stages | Full deployment — first time or after artifact changes |
| `connections-only` | Stages 4 & 5 only | Recreate/repair connections without redeploying artifacts |

---

## 7. Stage-by-Stage Walkthrough

### Stage 0 — Validate Branch

**Condition:** Always runs

**What it does:**
- Validates the branch follows the `uat/<project>/<version>` or `prod/<project>/<version>` format (3 segments minimum)
- Extracts the project name from the 2nd segment
- Sets the `projectName` output variable consumed by Stages 2 and 5
- Rejects runs from `main` or any branch that doesn't match `uat/*` or `prod/*`

---

### Stage 1 — Capture Artifact IDs

**Script:** [.deploy/capture_artifact_ids.ps1](.deploy/capture_artifact_ids.ps1)
**Runs on:** DEV workspace
**Condition:** `deployMode == 'full'`

**What it does:**
Reads DEV workspace artifact IDs and generates `parameter.yml` with find_replace entries for ID substitution.

**Example generated `parameter.yml`:**

```yaml
find_replace:
  - find_value: e0a0c0d0-c9d9-4a7e-978d-6ac8e79af581      # DEV workspace ID
    replace_value:
      _ALL_: $workspace.$id

  - find_value: f926c5dc-1362-4de5-9d37-ca29c1be3d98       # DEV lakehouse ID
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$id

  - find_value: 5c6d4df6-6984-45c3-b51b-d979fdcc62d9       # DEV SQL endpoint ID
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$sqlendpointid

  - find_value: ABC123XY.datawarehouse.fabric.microsoft.com # DEV SQL conn string
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$sqlendpoint
```

---

### Stage 2 — Deploy All Artifacts (Project Folder Only)

**Script:** [.deploy/deploy_fabric.py](.deploy/deploy_fabric.py)
**Runs on:** Target workspace (UAT/PROD)
**Key feature:** `--project <name>` → `folder_path_to_include=["/name"]`

**What it does:**
Deploys only items within the project's workspace folder, substituting DEV IDs with target environment IDs.

```bash
python .deploy/deploy_fabric.py \
  --workspace-id "$(targetWorkspaceId)" \
  --environment "$(environment)" \
  --project "$(projectName)"
```

**Feature flags enabled:**

| Flag | Purpose |
|------|---------|
| `enable_include_folder` | Enables `folder_path_to_include` filtering |
| `enable_lakehouse_unpublish` | Allows lakehouses to be removed as orphans |
| `enable_experimental_features` | Required for selective deployment features |

---

### Stage 3 — Initialize Data

**Script:** [.deploy/run_notebook.ps1](.deploy/run_notebook.ps1)
**Runs on:** Target workspace (UAT/PROD)

Triggers a Fabric Notebook in the target workspace to seed or initialize data. Polls for completion (max 60 minutes).

---

### Stage 4 — Create Semantic Model Connections

**Scripts:** [.deploy/create_sm_connections_stage.ps1](.deploy/create_sm_connections_stage.ps1), [.deploy/create_sm_connection.ps1](.deploy/create_sm_connection.ps1)
**Runs on:** Target workspace (UAT/PROD)

**What it does:**
1. Reads `connection_mapping.<env>.json` to find which connections are needed
2. Queries target Lakehouse SQL endpoint
3. Creates SQL connections (if they don't exist) using the service principal
4. Grants Owner access to the AAD group and users (from variable group)
5. Appends `semantic_model_binding` to `parameter.yml`

---

### Stage 5 — Deploy Semantic Models (Project Folder Only)

**Script:** [.deploy/deploy_fabric.py](.deploy/deploy_fabric.py) (with `--items SemanticModel`)
**Runs on:** Target workspace (UAT/PROD)

Redeploys only Semantic Models within the project folder, using the updated `parameter.yml` that now includes connection bindings.

```bash
python .deploy/deploy_fabric.py \
  --workspace-id "$(targetWorkspaceId)" \
  --environment "$(environment)" \
  --project "$(projectName)" \
  --items SemanticModel
```

---

## 8. Key Configuration Files

### `connection_mapping.uat.json` / `connection_mapping.prod.json`

Environment-specific connection mapping files. The pipeline automatically selects the correct file based on the detected environment.

```json
[
  {
    "connection_name": "my-connection-1939",
    "semantic_model_name": "conn_mgmt_sm",
    "lakehouse_name": "conn_mgmt_lh"
  }
]
```

### `parameter.yml`

**Auto-generated by the pipeline — do not edit manually.**

Built in Stage 1 (find_replace entries) and extended in Stage 4 (semantic_model_binding).

### `azure-pipelines.yml`

Defines the 6 pipeline stages (0–5), their order, conditions, and parameters.

---

## 9. Repository Structure

```
conn_mgmt/
│
├── azure-pipelines.yml                # Pipeline definition (6 stages)
├── connection_mapping.uat.json        # UAT: SM → Lakehouse connection mappings
├── connection_mapping.prod.json       # Prod: SM → Lakehouse connection mappings
├── connection_mapping.json            # Reference template (not used by pipeline)
├── parameter.yml                      # Auto-generated by pipeline (do not edit)
│
├── .deploy/                           # All deployment automation scripts
│   ├── capture_artifact_ids.ps1       # Stage 1: reads DEV IDs, generates parameter.yml
│   ├── deploy_fabric.py              # Stages 2 & 5: deploys artifacts via fabric-cicd
│   ├── install_fab_cli.ps1            # Installs ms-fabric-cli and authenticates
│   ├── run_notebook.ps1               # Stage 3: triggers notebook and polls for completion
│   ├── create_sm_connections_stage.ps1  # Stage 4 orchestrator
│   └── create_sm_connection.ps1      # Stage 4 functions: connection creation & access
│
├── conn_mgmt/                         # ← Project folder (items deployed by the pipeline)
│   ├── conn_mgmt_lh.Lakehouse/
│   ├── conn_mgmt_sm.SemanticModel/
│   ├── conn_mgmt_nb.Notebook/
│   ├── conn_mgmt_rp.Report/
│   └── conn_mgmt_df.Dataflow/
│
└── EXCLUDE/                           # Items excluded from deployment
    └── conn_mgmt_exclude_nb.Notebook/
```

> Items must be inside a workspace folder (subfolder matching the project name) for `folder_path_to_include` to filter them. Items at the repo root are considered "standalone" and are not affected by folder-level filters.

---

## 10. How to Run

### Full Deployment

1. Ensure items are inside the project folder (e.g., `conn_mgmt/conn_mgmt_sm.SemanticModel/`)
2. Create a release branch: `uat/conn_mgmt/1.0` from `main`
3. Trigger the pipeline manually on the `uat/conn_mgmt/1.0` branch
4. Pipeline detects: environment=UAT, project=conn_mgmt
5. Only items in the `/conn_mgmt/` folder are deployed

### Promote to Production

1. Create `prod/conn_mgmt/1.0` from `uat/conn_mgmt/1.0`
2. Trigger the pipeline on the `prod/conn_mgmt/1.0` branch

### Recreate Connections Only

Set `deployMode: connections-only` — skips Stages 1–3.

### Run Locally

```bash
pip install fabric-cicd
az login

python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT \
  --project conn_mgmt

# Deploy only Semantic Models
python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT \
  --project conn_mgmt \
  --items SemanticModel
```

---

## 11. Prerequisites

### Azure DevOps

- Pipeline connected to this repository
- **Azure service connection** (service principal) with workspace Member/Admin access
- **Variable groups** configured:
  - `fabric-uat` — `targetWorkspaceId`, `targetWorkspaceName`, `groupId`, `userIds`, `azureServiceConnection`
  - `fabric-prod` — `targetWorkspaceId`, `targetWorkspaceName`, `groupId`, `userIds`, `azureServiceConnection`
- Pipeline secret variables: `FAB_CLIENT_ID`, `FAB_CLIENT_SECRET`, `FAB_TENANT_ID`

### Fabric Workspace

- DEV, UAT, and PROD workspaces provisioned
- Items organized into **workspace folders** matching project names
- Service principal added as Member or Admin on all workspaces

### Runtime (installed automatically by pipeline)

| Tool | Version | Install |
|------|---------|---------|
| Python | 3.11+ | `UsePythonVersion@0` task |
| `fabric-cicd` | latest | `pip install fabric-cicd` |
| `ms-fabric-cli` | latest | `pip install ms-fabric-cli` |
| `powershell-yaml` | latest | `Install-Module powershell-yaml` |
