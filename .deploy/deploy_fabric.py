"""Deploy one workspace root; authenticate with Azure CLI before execution."""

import argparse
import logging
import os
from pathlib import Path
from uuid import UUID

from azure.identity import AzureCliCredential
from fabric_cicd import (
    FabricWorkspace,
    append_feature_flag,
    change_log_level,
    publish_all_items,
    unpublish_all_orphan_items,
)

from deployment_scope import ALL_ITEM_TYPES, BI_ITEM_TYPES, item_name, selected_items


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-id", required=True, type=UUID)
    parser.add_argument("--environment", required=True, choices=["UAT", "PROD"])
    parser.add_argument("--repository-directory", required=True, type=Path)
    parser.add_argument("--workspace-role", required=True, choices=["data", "bi"])
    parser.add_argument("--deploy-config")
    parser.add_argument("--items", nargs="+", choices=ALL_ITEM_TYPES)
    parser.add_argument("--unpublish-orphans", action="store_true",
                        help="Explicitly delete orphans; allowed only for a full workspace deployment.")
    return parser.parse_args()


def main():
    args = parse_args()
    root = args.repository_directory.resolve(strict=True)
    items = selected_items(root, args.workspace_role, args.deploy_config)
    allowed_types = BI_ITEM_TYPES if args.workspace_role == "bi" else set(ALL_ITEM_TYPES) - BI_ITEM_TYPES
    if args.items and not set(args.items) <= allowed_types:
        raise ValueError("Requested item types do not belong to this workspace role.")
    if args.unpublish_orphans and (args.deploy_config or args.items):
        raise ValueError("Orphan deletion requires an unfiltered full workspace deployment.")
    item_types = args.items or sorted(allowed_types)
    items = [item for item in items if item_name(item).rsplit(".", 1)[1] in item_types]
    if not items:
        raise ValueError("No selected items match the requested item types.")
    if not (root / "parameter.yml").is_file():
        raise FileNotFoundError(f"Generate {root / 'parameter.yml'} before deploying.")
    if os.getenv("SYSTEM_DEBUG", "false").lower() == "true":
        change_log_level("DEBUG")
    append_feature_flag("enable_items_to_include")
    append_feature_flag("enable_experimental_features")
    workspace = FabricWorkspace(
        workspace_id=str(args.workspace_id),
        environment=args.environment,
        repository_directory=str(root),
        item_type_in_scope=item_types,
        token_credential=AzureCliCredential(),
    )
    names = [item_name(item) for item in items]
    print(f"Deploying {args.workspace_role} to {args.workspace_id}: {names}", flush=True)
    # A single union selection lets fabric-cicd order dependencies across folders/items.
    publish_all_items(fabric_workspace_obj=workspace, items_to_include=names)
    if args.unpublish_orphans:
        append_feature_flag("enable_lakehouse_unpublish")
        unpublish_all_orphan_items(workspace)
    print("Deployment completed successfully.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, FileNotFoundError) as error:
        logging.error("%s", error)
        raise SystemExit(1) from error
