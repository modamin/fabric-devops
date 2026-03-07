'''
Log in with Azure CLI (az login) prior to execution
OR (Preferred) Use Az CLI ADO Tasks with a Service Connection

Usage:
    python deploy_fabric.py --items SemanticModel          # Deploy semantic models only
    python deploy_fabric.py --items SemanticModel Notebook  # Deploy semantic models and notebooks
    python deploy_fabric.py                                 # Deploy all items (default)
'''

import sys
import os
import argparse
from pathlib import Path

from azure.identity import AzureCliCredential
from fabric_cicd import FabricWorkspace, publish_all_items, unpublish_all_orphan_items, change_log_level, append_feature_flag

# Force unbuffered output like `python -u`
sys.stdout.reconfigure(line_buffering=True, write_through=True)
sys.stderr.reconfigure(line_buffering=True, write_through=True)

# Item type categories
ALL_ITEM_TYPES = [
    "Lakehouse",
    "Warehouse",
    "Eventhouse",
    "KQLDatabase",
    "MirroredDatabase",
    "SQLDatabase",
    "SemanticModel",
    "Notebook",
    "DataPipeline",
    "Report",
    "KQLQueryset",
    "Environment",
    "Reflex",
    "Eventstream",
    "CopyJob",
    "VariableLibrary",
    "Dataflow",
]


def parse_args():
    parser = argparse.ArgumentParser(description="Fabric CI/CD Deployment Script")
    parser.add_argument(
        "--items",
        dest="item_types",
        nargs="+",
        choices=ALL_ITEM_TYPES,
        default=None,
        help="Item types to deploy (space-separated). Omit to deploy all.",
    )
    parser.add_argument(
        "--workspace-id",
        dest="workspace_id",
        default=os.getenv("FABRIC_WORKSPACE_ID", "f37cedbf-e37a-42e6-822f-b75b93cc8118"),
        help="Fabric workspace ID (or set FABRIC_WORKSPACE_ID env var)",
    )
    parser.add_argument(
        "--environment",
        dest="environment",
        default=os.getenv("FABRIC_ENVIRONMENT", "UAT"),
        help="Target environment name (or set FABRIC_ENVIRONMENT env var)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    # Enable debugging if defined in Azure DevOps pipeline
    if os.getenv("SYSTEM_DEBUG", "false").lower() == "true":
        change_log_level("DEBUG")

    root_directory = str(Path(__file__).resolve().parent.parent)
    repository_directory = root_directory  # Use repo root, not a subdirectory

    item_type_in_scope = args.item_types if args.item_types else ALL_ITEM_TYPES

    print(f"Item Types: {item_type_in_scope}")
    print(f"Workspace ID: {args.workspace_id}")
    print(f"Environment: {args.environment}")

    # Use Azure CLI credential to authenticate
    token_credential = AzureCliCredential()

    append_feature_flag("enable_exclude_folder")
    append_feature_flag("enable_lakehouse_unpublish")
    append_feature_flag("enable_experimental_features")

    # Initialize the FabricWorkspace object with the required parameters
    target_workspace = FabricWorkspace(
        workspace_id=args.workspace_id,
        environment=args.environment,
        repository_directory=repository_directory,
        item_type_in_scope=item_type_in_scope,
        token_credential=token_credential,
    )

    # Publish all items defined in item_type_in_scope
    publish_all_items(
        fabric_workspace_obj=target_workspace,
        folder_path_exclude_regex="EXCLUDE.*"
    )

    # Unpublish all items defined in item_type_in_scope not found in repository
    unpublish_all_orphan_items(target_workspace)

    print("Deployment completed successfully.")


if __name__ == "__main__":
    main()