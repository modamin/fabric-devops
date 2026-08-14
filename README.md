# Fabric Connection Management — CI/CD Pipeline

> **Purpose:** This document explains the end-to-end DevOps automation that deploys Microsoft Fabric workspaces across environments (DEV → UAT → PROD) using a trunk-based branching model with config-driven selective deployment, solves the ID-remapping problem, and automatically creates and binds SQL connections for Semantic Models.

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

This repository follows **trunk-based development (Option 4)** for Fabric CI/CD — specifically, trunk-based development with short-lived, environment-scoped **release branches** (a "release-branch-per-environment" pattern). It is **not** Git Flow: there is no long-lived `develop` branch and no permanent `release`/`hotfix`/`feature` branch hierarchy. What gets deployed is driven by [`.deploy/config/deployment_selection.yml`](.deploy/config/deployment_selection.yml), **not** by the branch name.

### Branch Strategy

| Branch | Purpose | Deployment |
|--------|---------|------------|
| `main` | Integration branch | Synced to **dev** workspace via **Update from GIT** (no pipeline runs) |
| `uat/x.y` | Release candidate | Deploys to **UAT** workspace via `fabric-cicd` |
| `prod/x.y` | Production release | Deploys to **PROD** workspace via `fabric-cicd` |

### Release Workflow

```
main (dev workspace — synced via "Update from GIT")
  │
  ├── Create Branch ──▶ uat/1.0 ──▶ fabric-cicd ──▶ UAT workspace
  │                     │
  │                Create Branch ──▶ prod/1.0 ──▶ fabric-cicd ──▶ Prod workspace
  │
  ├── Create Branch ──▶ uat/1.1 ──▶ fabric-cicd ──▶ UAT workspace
  │                     │
  │                Create Branch ──▶ prod/1.1 ──▶ fabric-cicd ──▶ Prod workspace
  │
  └── ...
```

### Selecting What to Deploy

The branch name only encodes the **environment** and **version**. The set of folders and items to deploy is defined in the selective-deployment config:

```
uat/<version>
 └─┬─┘
   │
   ▼
 environment (UAT/PROD) auto-detected from branch prefix

.deploy/config/deployment_selection.yml
   │
   ▼
 folders + single items to deploy (see Section 8)
```

- The pipeline auto-detects the **environment** from the branch prefix (`uat/*` or `prod/*`)
- The **folders/items** to deploy come from [`.deploy/config/deployment_selection.yml`](.deploy/config/deployment_selection.yml)
- Items not listed in the config are **not** deployed
- This allows multiple teams/projects to share a single repository and workspace

### Release History

| UAT Branches | Prod Branches |
|--------------|---------------|
| `uat/1.0` | `prod/1.0` |
| `uat/1.1` | `prod/1.1` |

### Key Principles

- **No long-lived branches** for UAT and PROD — each release creates new short-lived branches
- **main** is always the source of truth — developers commit to main, which syncs to the dev workspace
- **Environment is auto-detected** from the branch prefix (`uat/*` or `prod/*`)
- **What to deploy** is config-driven via `.deploy/config/deployment_selection.yml`
- **Pipeline rejects runs from main** — the dev workspace is managed entirely via "Update from GIT"
- **Branch must have at least 2 segments** — `env/version` format (e.g. `uat/1.0`) is validated

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
│  Branch: uat/1.0 → env=UAT   (deployment scope from config)          │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐              │
│  │  Stage 1     │    │  Stage 2     │    │  Stage 3     │              │
│  │  Capture     │───▶│  Selective   │───▶│  Initialize  │              │
│  │  Artifact IDs│    │  Deployment  │    │  Data        │              │
│  │              │    │  (config)    │    │              │              │
│  └──────────────┘    └──────────────┘    └──────┬───────┘              │
│                                                  │                      │
│                         ┌────────────────────────▼─────────────┐       │
│                         │  Stage 4: Create SM Connections       │       │
│                         │  (Create SQL connections in target)   │       │
│                         └────────────────────────┬─────────────┘       │
│                                                  │                      │
│                         ┌────────────────────────▼─────────────┐       │
│                         │  Stage 5: Deploy Semantic Models      │       │
│                         │  (selected items, with bindings)      │       │
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

#### Important: selective deployment caveat

When a deployment includes a mix of folder-level includes and individual single items, the implementation must use a separate `FabricWorkspace` instance for each pass.

`fabric-cicd` stores selective deployment filters (`folder_path_to_include`, `items_to_include`) on the workspace object. If the same workspace object is reused across passes, the first pass can leak its folder filter into the second pass and cause items in other folders to be skipped. This is why the repository's deploy script performs the deployment as two separate passes:

1. Folder pass: deploy the project folder and its subfolders
2. Single-item pass: deploy named items like `item_name.Notebook`

The fix is to create a fresh workspace object for each publish call so that filter state does not persist between passes.

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
| `uat/*` | UAT | `fabric-uat` |
| `prod/*` | PROD | `fabric-prod` |
| `main` | *(rejected)* | — |

### Pipeline Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `devWorkspaceName` | Name of the DEV workspace to read IDs from | `cicd-conn-mgmt-dev` |
| `initNotebookName` | Name of the notebook to run for data initialization | `conn_mgmt_init_nb` |
| `selectiveDeployConfig` | Path to the selective-deployment YAML config | `.deploy/config/deployment_selection.yml` |

### Stage Toggles

Each stage is enabled or disabled independently before queueing the run — there is no combined "deploy mode". Set the toggles for the stages you want to run.

| Toggle | Stage | Default |
|--------|-------|---------|
| `runCaptureArtifactIds` | Capture Artifact IDs | `true` |
| `runDeployAllArtifacts` | Deploy All Artifacts (whole repo) | `false` |
| `runSelectiveDeployment` | Selective Deployment (folders + single items) | `true` |
| `runInitializeData` | Initialize Data | `true` |
| `runCreateSMConnections` | Create SM Connections | `true` |
| `runDeploySemanticModels` | Deploy Semantic Models | `true` |

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

---

## 7. Stage-by-Stage Walkthrough

### Stage 0 — Validate Branch

**Condition:** Always runs

**What it does:**
- Validates the branch follows the `uat/<version>` or `prod/<version>` format (at least 2 segments, e.g. `uat/1.0`)
- Auto-detects the environment (UAT/PROD) from the branch prefix
- Rejects runs from `main` or any branch that doesn't match `uat/*` or `prod/*`

---

### Stage 1 — Capture Artifact IDs

**Script:** [.deploy/capture_artifact_ids.ps1](.deploy/capture_artifact_ids.ps1)
**Runs on:** DEV workspace
**Condition:** `runCaptureArtifactIds == true`

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

  - find_value: Navigation\s*=\s*Navigation\{\[dataflowId\s*=\s*"(0187104d-7a35-4abe-a2ca-a241ec81c8f1)"\]\}
    replace_value:
      _ALL_: $items.Dataflow.Source Dataflow.$id
    is_regex: "true"
    item_type: Dataflow
    item_name: Referencing Dataflow
    file_path: /Project_B/Referencing Dataflow.Dataflow/mashup.pq

  - find_value: ABC123XY.datawarehouse.fabric.microsoft.com # DEV SQL conn string
    replace_value:
      _ALL_: $items.Lakehouse.conn_mgmt_lh.$sqlendpoint
```

---

### Stage 2 — Selective Deployment (config-driven)

**Script:** [.deploy/deploy_fabric.py](.deploy/deploy_fabric.py)
**Runs on:** Target workspace (UAT/PROD)
**Key feature:** `--deploy-config <yaml>` → deploys the folders and single items listed in [`.deploy/config/deployment_selection.yml`](.deploy/config/deployment_selection.yml)

**What it does:**
Deploys the folders and individual items defined in the selective-deployment config, substituting DEV IDs with target environment IDs. When the config lists both folders and single items, deployment runs in two passes (see [Section 8](#8-key-configuration-files)).

```bash
python .deploy/deploy_fabric.py \
  --workspace-id "$(targetWorkspaceId)" \
  --environment "$(environment)" \
  --deploy-config "$(selectiveDeployConfig)"
```

> To deploy the entire repository instead, enable the separate **Deploy All Artifacts** stage, which runs `deploy_fabric.py` with no folder/item filter.

**Feature flags enabled:**

| Flag | Purpose |
|------|---------|
| `enable_include_folder` | Enables `folder_path_to_include` filtering |
| `enable_items_to_include` | Enables `items_to_include` (single-item) filtering |
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
1. Reads the `<env>` section of `.deploy/config/connection_mapping.yml` to find which connections are needed
2. Queries target Lakehouse SQL endpoint
3. Creates SQL connections (if they don't exist) using the service principal
4. Grants Owner access to the AAD group and users (from variable group)
5. Appends `semantic_model_binding` to `parameter.yml`

---

### Stage 5 — Deploy Semantic Models (config-driven)

**Script:** [.deploy/deploy_fabric.py](.deploy/deploy_fabric.py) (with `--items SemanticModel`)
**Runs on:** Target workspace (UAT/PROD)

Redeploys only the Semantic Models within the selective-deployment scope, using the updated `parameter.yml` that now includes connection bindings.

```bash
python .deploy/deploy_fabric.py \
  --workspace-id "$(targetWorkspaceId)" \
  --environment "$(environment)" \
  --deploy-config "$(selectiveDeployConfig)" \
  --items SemanticModel
```

---

## 8. Key Configuration Files

### `.deploy/config/connection_mapping.yml`

A single mapping file with one section per environment (`uat` / `prod`). The pipeline reads the section matching the detected environment.

```yaml
uat:
  - connection_name: my-connection-1939
    semantic_model_name: conn_mgmt_sm
    lakehouse_name: conn_mgmt_lh

prod:
  - connection_name: my-connection-1939
    semantic_model_name: conn_mgmt_sm
    lakehouse_name: conn_mgmt_lh
```

### `parameter.yml`

**Auto-generated by the pipeline — do not edit manually.**

Built in Stage 1 (find_replace entries) and extended in Stage 4 (semantic_model_binding).

### `.deploy/config/deployment_selection.yml`

Config for **selective deployment** via `deploy_fabric.py --deploy-config`. Lets you deploy a combination of whole folders and individual items in a single run:

```yaml
folders:
  - Project_D                 # deploys this folder AND all of its subfolders

files:
  - conn_mgmt_single_items_nb.Notebook   # single items, in "item_name.item_type" format
```

- `folders` — each listed folder and all of its subfolders are deployed (the script walks the repo folder structure, so subfolders do not need to be listed).
- `files` — individual items, in `item_name.item_type` format.

When both `folders` and `files` are present, the script runs a **two-pass deployment** (one pass for folders, one for single items). Each pass uses its own `FabricWorkspace` object so selective-deployment filters do not leak between passes — see the caveat in [Section 4](#4-tools--libraries).

### `azure-pipelines.yml`

Defines the 6 pipeline stages (0–5), their order, conditions, and parameters.

---

## 9. Repository Structure

```
conn_mgmt/
│
├── azure-pipelines.yml                # Pipeline definition (6 stages)
├── parameter.yml                      # Auto-generated by pipeline (do not edit)
│
├── .deploy/                           # All deployment automation scripts + config
│   ├── config/                        # Deployment configuration (YAML)
│   │   ├── deployment_selection.yml   # Folders + single items to deploy (selective deployment)
│   │   └── connection_mapping.yml     # SM → Lakehouse connection mappings (uat + prod sections)
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

1. List the folders/items to deploy in [`.deploy/config/deployment_selection.yml`](.deploy/config/deployment_selection.yml)
2. Create a release branch: `uat/1.0` from `main`
3. Trigger the pipeline manually on the `uat/1.0` branch
4. Pipeline detects: environment=UAT
5. Only the folders/items listed in the config are deployed

### Promote to Production

1. Create `prod/1.0` from `uat/1.0`
2. Trigger the pipeline on the `prod/1.0` branch

### Recreate Connections Only

Disable the earlier stage toggles (Capture Artifact IDs, Selective Deployment, Initialize Data) and run only the connection + Semantic Model stages.

### Run Locally

```bash
pip install fabric-cicd
az login

# Deploy the folders/items from the selection config
python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT \
  --deploy-config .deploy/config/deployment_selection.yml

# Deploy only Semantic Models within the selection scope
python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT \
  --deploy-config .deploy/config/deployment_selection.yml \
  --items SemanticModel
```

### Selective Deployment (folders + single items)

Use `--deploy-config` to deploy a mix of whole folders and individual items defined in a YAML file (see [`.deploy/config/deployment_selection.yml`](.deploy/config/deployment_selection.yml)):

```bash
python .deploy/deploy_fabric.py \
  --workspace-id <workspace-guid> \
  --environment UAT \
  --deploy-config .deploy/config/deployment_selection.yml
```

When the config contains both `folders` and `files`, the script deploys them as two separate passes (folders first, then single items). Each pass gets a fresh `FabricWorkspace` object so the folder filter from the first pass cannot cause single items in other folders to be skipped.

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
