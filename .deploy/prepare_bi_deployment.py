"""Resolve BI references against the target data workspace before publishing."""

import argparse
import json
import logging
import re
from pathlib import Path
from uuid import UUID

import yaml

from deployment_scope import item_metadata, report_model, selected_items


def read_mapping(path: Path) -> dict:
    with path.open(encoding="utf-8-sig") as stream:
        mapping = json.load(stream)
    UUID(mapping["workspace_id"])
    return mapping


def definition_text(item: Path) -> str:
    suffixes = {".tmdl", ".json", ".pbir", ".pbism"}
    return "\n".join(
        path.read_text(encoding="utf-8-sig")
        for path in sorted(item.rglob("*"))
        if path.is_file() and path.suffix in suffixes and "StaticResources" not in path.parts
    )


def prepare(root: Path, config: str | None, source_data: dict, target_data: dict,
            source_bi: dict, target_bi: dict, environment: str) -> tuple[dict, dict, list[dict]]:
    environment = environment.upper()
    if environment not in {"UAT", "PROD"}:
        raise ValueError(f"Unsupported deployment environment: {environment}")
    workspace_ids = [mapping["workspace_id"] for mapping in (source_data, target_data, source_bi, target_bi)]
    for workspace_id in workspace_ids:
        UUID(workspace_id)
    if len(set(workspace_ids)) != 4:
        raise ValueError("Source and target data/BI workspace IDs must all be distinct.")
    items = selected_items(root, "bi", config)
    models = {item_metadata(item)["displayName"] for item in items if item_metadata(item)["type"] == "SemanticModel"}
    replacements = []
    reports = []
    dependencies = []
    model_sources = {}

    for item in items:
        metadata = item_metadata(item)
        name, kind = metadata["displayName"], metadata["type"]
        text = definition_text(item)
        item_replacements = {}

        if kind == "SemanticModel":
            if re.search(r"\bSql\.Database\s*\(", text, flags=re.IGNORECASE):
                raise ValueError(f"{name} still uses a SQL source. Convert it to Direct Lake on OneLake before deployment.")
            sources = {(str(UUID(workspace)), str(UUID(lakehouse))) for workspace, lakehouse in re.findall(
                r'AzureStorage\.DataLake\(\s*"https://onelake\.dfs\.fabric\.microsoft\.com/'
                r'([0-9a-f-]{36})/([0-9a-f-]{36})/?"',
                text, flags=re.IGNORECASE,
            )}
            modes = re.findall(r"^\s*mode:\s*(\w+)", text, flags=re.MULTILINE)
            if len(sources) != 1 or not modes or any(mode != "directLake" for mode in modes):
                raise ValueError(f"{name} must use Direct Lake on OneLake with one GUID-based lakehouse source.")
            model_sources[name] = sources.pop()

        def add(source: str, target: str) -> bool:
            matches = set(re.findall(re.escape(source), text, flags=re.IGNORECASE))
            for match in sorted(matches):
                previous = item_replacements.get(match)
                if previous is not None and previous != target:
                    raise ValueError(f"Conflicting replacement for {match} in {name}.")
                item_replacements[match] = target
            return bool(matches)

        add(source_data["workspace_id"], target_data["workspace_id"])
        add(source_bi["workspace_id"], "$workspace.$id")
        known_data_values = {source_data["workspace_id"].casefold()}
        for item_type, source_items in source_data["items"].items():
            for data_name, info in source_items.items():
                source_values = {"id": info["id"]}
                if item_type == "Lakehouse":
                    endpoint = source_data["sql_endpoints"].get(data_name, {})
                    source_values.update({f"sql_{key}": value for key, value in endpoint.items()})
                known_data_values.update(value.casefold() for value in source_values.values())
                referenced = {
                    key: value for key, value in source_values.items()
                    if re.search(re.escape(value), text, flags=re.IGNORECASE)
                }
                # Lakehouses can share a SQL server. The item/database ID, not
                # that server alone, identifies which lakehouse a model uses.
                if not referenced or set(referenced) == {"sql_connectionString"}:
                    continue
                target_info = target_data["items"].get(item_type, {}).get(data_name)
                if not target_info:
                    raise ValueError(f"{name} requires missing target data item {data_name}.{item_type}.")
                target_values = {"id": target_info["id"]}
                if item_type == "Lakehouse":
                    target_values.update({
                        f"sql_{key}": value
                        for key, value in target_data["sql_endpoints"].get(data_name, {}).items()
                    })
                for key, source in referenced.items():
                    target = target_values.get(key)
                    if not target:
                        raise ValueError(f"{name}: target {data_name} is missing {key}; endpoint is not ready.")
                    add(source, target)
                dependencies.append({"consumer": name, "type": item_type, "name": data_name,
                                     "id": target_info["id"]})

        # Reject stale DEV references that cannot be resolved from the source inventory.
        for workspace_id, item_id in re.findall(
            r"https://onelake\.dfs\.fabric\.microsoft\.com/([0-9a-f-]{36})/([0-9a-f-]{36})",
            text, flags=re.IGNORECASE,
        ):
            if workspace_id.casefold() != source_data["workspace_id"].casefold() or item_id.casefold() not in known_data_values:
                raise ValueError(f"{name} has an unrecognized OneLake source; resync DEV definitions.")
        for model_name, info in source_bi["items"].get("SemanticModel", {}).items():
            if re.search(re.escape(info["id"]), text, flags=re.IGNORECASE):
                if model_name not in models and model_name not in target_bi["items"].get("SemanticModel", {}):
                    raise ValueError(f"{name} requires missing BI model {model_name}.")
                add(info["id"], f"$items.SemanticModel.{model_name}.$id")
        for source, target in item_replacements.items():
            replacements.append({
                "find_value": source, "replace_value": {"_ALL_": target},
                "item_type": kind, "item_name": name,
            })
        if kind == "Report":
            model_name = item_metadata(report_model(item, root))["displayName"]
            if model_name not in models and model_name not in target_bi["items"].get("SemanticModel", {}):
                raise ValueError(f"Report {name} requires missing target BI model {model_name}.")
            reports.append({"name": name, "model": model_name})

    selected_connections = []
    target_workspace_id = str(UUID(target_data["workspace_id"]))
    for model, (source_workspace_id, source_id) in sorted(model_sources.items()):
        matches = [
            name for name, info in source_data["items"].get("Lakehouse", {}).items()
            if str(UUID(info["id"])) == source_id
        ]
        if source_workspace_id != str(UUID(source_data["workspace_id"])) or len(matches) != 1:
            raise ValueError(f"{model}: OneLake source must resolve to exactly one lakehouse in the DEV data workspace.")
        lakehouse = matches[0]
        target = target_data["items"].get("Lakehouse", {}).get(lakehouse)
        if not target:
            raise ValueError(f"{model} requires missing target data item {lakehouse}.Lakehouse.")
        target_id = str(UUID(target["id"]))
        selected_connections.append({
            "connection_name": f"onelake-{environment.lower()}-{target_workspace_id}-{target_id}",
            "semantic_model_name": model,
            "lakehouse_name": lakehouse,
            "onelake_url": f"https://onelake.dfs.fabric.microsoft.com/{target_workspace_id}/{target_id}/",
        })
    manifest = {
        "data_workspace_id": target_data["workspace_id"],
        "bi_workspace_id": target_bi["workspace_id"],
        "dependencies": dependencies, "models": sorted(models), "reports": reports,
        "find_replace": replacements,
        "connections": selected_connections,
    }
    return {"find_replace": replacements} if replacements else {}, manifest, selected_connections


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-directory", type=Path, required=True)
    parser.add_argument("--deploy-config")
    for name in ("source-data", "target-data", "source-bi", "target-bi"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--environment", choices=["UAT", "PROD"], required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    parameters, manifest, selected_connections = prepare(
        args.repository_directory, args.deploy_config,
        read_mapping(args.source_data), read_mapping(args.target_data),
        read_mapping(args.source_bi), read_mapping(args.target_bi), args.environment,
    )
    args.output_directory.mkdir(parents=True, exist_ok=True)
    (args.repository_directory / "parameter.yml").write_text(
        yaml.safe_dump(parameters, sort_keys=False), encoding="utf-8",
    )
    (args.output_directory / "bi_dependencies.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8",
    )
    (args.output_directory / "selected_connections.yml").write_text(
        yaml.safe_dump({args.environment.lower(): selected_connections}, sort_keys=False), encoding="utf-8",
    )
    print(f"Validated {len(manifest['models'])} models and {len(manifest['reports'])} reports.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, FileNotFoundError) as error:
        logging.error("%s", error)
        raise SystemExit(1) from error
