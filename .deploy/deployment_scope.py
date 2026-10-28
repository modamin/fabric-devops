"""Resolve deployment selections within a single workspace root."""

import json
from pathlib import Path

import yaml

BI_ITEM_TYPES = {"SemanticModel", "Report"}
ALL_ITEM_TYPES = [
    "Lakehouse", "Warehouse", "Eventhouse", "KQLDatabase", "MirroredDatabase",
    "SQLDatabase", "SemanticModel", "Notebook", "DataPipeline", "Report",
    "KQLQueryset", "Environment", "Reflex", "Eventstream", "CopyJob",
    "VariableLibrary", "Dataflow", "GraphQLApi",
]


def item_metadata(item: Path) -> dict:
    with (item / ".platform").open(encoding="utf-8-sig") as stream:
        return json.load(stream)["metadata"]


def item_name(item: Path) -> str:
    metadata = item_metadata(item)
    return f"{metadata['displayName']}.{metadata['type']}"


def workspace_items(root: Path, role: str) -> list[Path]:
    root = root.resolve(strict=True)
    items = sorted(platform.parent for platform in root.rglob(".platform"))
    names = set()
    for item in items:
        metadata = item_metadata(item)
        kind = metadata["type"]
        if kind not in ALL_ITEM_TYPES:
            raise ValueError(f"Unsupported item type {kind}: {item}")
        if (kind in BI_ITEM_TYPES) != (role == "bi"):
            raise ValueError(f"{kind} item is in the wrong workspace root: {item}")
        name = item_name(item)
        if name.casefold() in names:
            raise ValueError(f"Duplicate item name in {role} workspace: {name}")
        names.add(name.casefold())
    return items


def load_deploy_config(config_path: str) -> tuple[list[str], list[str]]:
    with Path(config_path).open(encoding="utf-8-sig") as stream:
        config = yaml.safe_load(stream)
    if not isinstance(config, dict) or set(config) - {"folders", "files"}:
        raise ValueError("Deploy config must contain only 'folders' and 'files'.")
    folders, files = config.get("folders", []), config.get("files", [])
    for values in (folders, files):
        if not isinstance(values, list) or any(
            not isinstance(value, str) or not value.strip() for value in values
        ):
            raise ValueError("'folders' and 'files' must be lists of nonempty strings.")
    if not folders and not files:
        raise ValueError("Deployment selection is empty; select items or use full mode.")
    return folders, files


def selected_items(root: Path, role: str, config_path: str | None = None) -> list[Path]:
    root = root.resolve(strict=True)
    items = workspace_items(root, role)
    if config_path is None:
        if not items:
            raise ValueError(f"No items found in {root}")
        return items
    folders, files = load_deploy_config(config_path)
    selected = set()
    for folder in folders:
        relative = Path(folder.replace("\\", "/"))
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Folder must be relative to the workspace root: {folder}")
        base = (root / relative).resolve(strict=True)
        if not base.is_relative_to(root) or not base.is_dir() or base in items:
            raise ValueError(f"Invalid workspace folder: {folder}")
        matches = [item for item in items if item.is_relative_to(base)]
        if not matches:
            raise ValueError(f"No Fabric items in selected folder: {folder}")
        selected.update(matches)
    by_name = {item_name(item): item for item in items}
    for name in files:
        if name not in by_name:
            raise ValueError(f"Selected item not found in {role} workspace: {name}")
        selected.add(by_name[name])
    return sorted(selected)


def report_model(report: Path, root: Path) -> Path:
    with (report / "definition.pbir").open(encoding="utf-8-sig") as stream:
        definition = json.load(stream)
    reference = definition["datasetReference"]
    if "byPath" not in reference:
        raise ValueError(f"Report must reference a BI-local model byPath: {report}")
    model = (report / reference["byPath"]["path"]).resolve(strict=True)
    if not model.is_relative_to(root.resolve()) or item_metadata(model)["type"] != "SemanticModel":
        raise ValueError(f"Report model must be inside the BI root: {report}")
    return model
