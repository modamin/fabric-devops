'''
Log in with Azure CLI (az login) prior to execution
OR (Preferred) Use Az CLI ADO Tasks with a Service Connection

Usage:
    python deploy_fabric.py --items SemanticModel          # Deploy semantic models only
    python deploy_fabric.py --items SemanticModel Notebook  # Deploy semantic models and notebooks
    python deploy_fabric.py                                 # Deploy all items (default)
    python deploy_fabric.py --project Project_A            # Deploy a single project folder
    python deploy_fabric.py --deploy-config selection.yml  # Selective deployment (folders + single items)

Selective deployment config (YAML) format:
    folders:
      - Project_A                 # Deploys this folder and all of its subfolders
      - Project_B/nested_folder   # Nested folder paths are supported
    files:
      - conn_mgmt_nb.Notebook     # Single items, in "item_name.item_type" format
      - conn_mgmt_sm.SemanticModel
'''

import sys
import os
import argparse
from pathlib import Path

import yaml
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


def is_item_directory(name):
    """Return True if a directory name represents a Fabric item (e.g. 'foo.Notebook')."""
    suffix = name.rsplit(".", 1)[-1] if "." in name else ""
    return suffix in ALL_ITEM_TYPES


def discover_folder_paths(repository_directory, folder):
    """Discover the Fabric folder path for `folder` and all of its subfolders.

    Fabric folder paths mirror the repository directory structure. Item
    directories (e.g. 'foo.Notebook') are not folders and are skipped. Every
    folder that directly contains items must be listed explicitly because
    fabric-cicd does not publish items under an ancestor folder unless that
    folder is itself included.

    Returns a list of folder paths such as ['/Project_A', '/Project_A/sub'].
    """
    folder_rel = folder.strip("/")
    base = Path(repository_directory) / folder_rel

    if not base.is_dir():
        raise FileNotFoundError(
            f"Folder '{folder}' not found in repository at: {base}"
        )

    paths = []
    for dirpath, dirnames, _ in os.walk(base):
        rel = Path(dirpath).relative_to(repository_directory).as_posix()
        paths.append("/" + rel)
        # Do not descend into Fabric item directories.
        dirnames[:] = sorted(d for d in dirnames if not is_item_directory(d))

    return paths


def load_deploy_config(config_path):
    """Load and validate the selective-deployment YAML config.

    Returns a tuple (folders, files) where both are lists of strings.
    """
    path = Path(config_path)
    if not path.is_file():
        raise FileNotFoundError(f"Deploy config file not found: {path}")

    with path.open("r", encoding="utf-8") as f:
        config = yaml.safe_load(f) or {}

    if not isinstance(config, dict):
        raise ValueError(
            "Deploy config must be a mapping with 'folders' and/or 'files' keys."
        )

    folders = config.get("folders") or []
    files = config.get("files") or []

    if not isinstance(folders, list) or not isinstance(files, list):
        raise ValueError("'folders' and 'files' sections must be lists.")

    # Normalize single items to bare 'item_name.item_type' (strip any path parts).
    files = [Path(str(f)).name for f in files]

    return [str(f) for f in folders], files


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
    parser.add_argument(
        "--project",
        dest="project",
        default=None,
        help="Project folder name to deploy (folder-level include). Ignored when --deploy-config is used.",
    )
    parser.add_argument(
        "--deploy-config",
        dest="deploy_config",
        default=None,
        help=(
            "Path to a YAML file describing a selective deployment. "
            "The file may contain a 'folders' section (each folder and all of "
            "its subfolders are deployed) and a 'files' section (single items "
            "in 'item_name.item_type' format)."
        ),
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

    append_feature_flag("enable_include_folder")
    append_feature_flag("enable_items_to_include")
    append_feature_flag("enable_lakehouse_unpublish")
    append_feature_flag("enable_experimental_features")

    def new_workspace():
        """Create a fresh FabricWorkspace object.

        fabric-cicd stores selective-deployment filters (folder_path_to_include,
        items_to_include, etc.) on the workspace object and only overwrites them
        when a non-None value is passed. Reusing one object across multiple
        publish_all_items calls therefore leaks the previous call's filters into
        the next call. Use a new object per publish pass to keep passes isolated.
        """
        return FabricWorkspace(
            workspace_id=args.workspace_id,
            environment=args.environment,
            repository_directory=repository_directory,
            item_type_in_scope=item_type_in_scope,
            token_credential=token_credential,
        )

    target_workspace = new_workspace()

    if args.deploy_config:
        # Selective deployment driven by a YAML config (folders + single items).
        folders, files = load_deploy_config(args.deploy_config)
        print(f"Deploy config: {args.deploy_config}")
        print(f"Requested folders: {folders}")
        print(f"Requested single items: {files}")

        # Expand each requested folder into its full set of Fabric folder paths
        # (the folder itself plus every subfolder), preserving order and removing
        # duplicates.
        folder_paths = []
        for folder in folders:
            for path in discover_folder_paths(repository_directory, folder):
                if path not in folder_paths:
                    folder_paths.append(path)

        if not folder_paths and not files:
            print("Deploy config contains no folders or files. Nothing to deploy.")
            return

        # Folder-level and item-level filters are combined as an intersection when
        # passed to a single publish call, so deploy them in separate passes to
        # achieve the desired union (folders OR single items). Each pass uses its
        # own FabricWorkspace object so the folder filter from the first pass does
        # not leak into the second pass (which would cause single items in
        # non-included folders to be skipped).
        if folder_paths:
            print(f"Deploying folders and subfolders: {folder_paths}")
            publish_all_items(
                fabric_workspace_obj=new_workspace(),
                folder_path_to_include=folder_paths,
            )

        if files:
            print(f"Deploying single items: {files}")
            publish_all_items(
                fabric_workspace_obj=new_workspace(),
                items_to_include=files,
            )
    elif args.project:
        # Publish only items within the project's folder
        print(f"Deploying project: {args.project} (folder: /{args.project})")
        publish_all_items(
            fabric_workspace_obj=target_workspace,
            folder_path_to_include=[f"/{args.project}"],
        )
    else:
        # Deploy everything in scope
        print("Deploying all items in scope.")
        publish_all_items(fabric_workspace_obj=target_workspace)

    # Unpublish all items defined in item_type_in_scope not found in repository
    unpublish_all_orphan_items(target_workspace)

    print("Deployment completed successfully.")


if __name__ == "__main__":
    main()