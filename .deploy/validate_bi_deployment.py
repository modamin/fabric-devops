"""Validate deployed BI references and bindings, and optionally refresh selected models."""

import argparse
import base64
import json
import logging
import re
import time
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID

import requests
import yaml
from azure.identity import AzureCliCredential

FABRIC = "https://api.fabric.microsoft.com/v1/"
POWER_BI = "https://api.powerbi.com/v1.0/myorg/"

def trusted_operation_location(location: str, public_host: str) -> str:
    parsed = urlsplit(location)
    host = parsed.hostname or ""
    trusted_host = host == public_host or re.fullmatch(
        r"wabi-[a-z0-9]+(?:-[a-z0-9]+)*\.analysis\.windows\.net", host,
    )
    if (parsed.scheme != "https" or not trusted_host
            or parsed.netloc.lower() not in {host, f"{host}:443"}
            or parsed.query or parsed.fragment):
        raise ValueError(f"Invalid operation Location: {location}")
    return parsed.path


class FabricApi:
    def __init__(self):
        self.credential = AzureCliCredential()

    def request(self, method: str, url: str, body: dict | None = None) -> requests.Response:
        if url.startswith(FABRIC):
            scope = "https://api.fabric.microsoft.com/.default"
        elif url.startswith(POWER_BI):
            scope = "https://analysis.windows.net/powerbi/api/.default"
        else:
            raise ValueError(f"Unexpected API URL: {url}")
        response = requests.request(
            method, url, headers={"Authorization": f"Bearer {self.credential.get_token(scope).token}"},
            timeout=120, json=body,
        )
        response.raise_for_status()
        return response

    def list_items(self, url: str) -> list[dict]:
        values = []
        while url:
            body = self.request("GET", url).json()
            values.extend(body["value"])
            url = body.get("continuationUri")
        return values

    def model_definition(self, workspace_id: str, model_id: str) -> str:
        response = self.request("POST", f"{FABRIC}workspaces/{workspace_id}/semanticModels/{model_id}/getDefinition")
        if response.status_code == 202:
            operation_id = response.headers.get("x-ms-operation-id")
            if not operation_id:
                location = response.headers.get("Location", "")
                path = trusted_operation_location(location, "api.fabric.microsoft.com")
                match = re.fullmatch(r"/v1/operations/([0-9a-fA-F-]{36})/?", path)
                if not match:
                    raise ValueError(f"GetDefinition returned an invalid operation Location: {location}")
                operation_id = match.group(1)
            try:
                operation_id = str(UUID(operation_id))
            except ValueError as error:
                raise ValueError(f"GetDefinition returned an invalid operation ID: {operation_id}") from error
            # Fabric supports public operation polling even when Location points to a regional backend.
            operation_url = f"{FABRIC}operations/{operation_id}"
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                time.sleep(min(int(response.headers.get("Retry-After", "5")), 30))
                response = self.request("GET", operation_url)
                status = response.json()["status"]
                if status in {"Failed", "Cancelled"}:
                    raise ValueError(f"GetDefinition failed for model {model_id}: {response.text}")
                if status == "Succeeded":
                    response = self.request("GET", operation_url.rstrip("/") + "/result")
                    break
            else:
                raise TimeoutError(f"GetDefinition timed out for model {model_id}.")
        return "\n".join(
            base64.b64decode(part["payload"], validate=True).decode("utf-8-sig")
            for part in response.json()["definition"]["parts"]
            if part["path"] != ".platform"
        )

    def refresh_model(self, workspace_id: str, model_id: str, name: str, timeout: int = 600) -> None:
        if timeout <= 0:
            raise ValueError("Refresh timeout must be positive.")
        url = f"{POWER_BI}groups/{workspace_id}/datasets/{model_id}/refreshes"
        print(f"Starting semantic model refresh: {name} ({model_id})", flush=True)
        response = self.request("POST", url, body={"type": "full", "commitMode": "transactional"})
        logging.info(
            "Refresh response for %s: HTTP %s; Location=%r; x-ms-request-id=%r; Retry-After=%r",
            name, response.status_code, response.headers.get("Location"),
            response.headers.get("x-ms-request-id"), response.headers.get("Retry-After"),
        )
        if response.status_code != 202:
            raise ValueError(f"{name}: refresh request was not accepted: HTTP {response.status_code}.")
        location = response.headers.get("Location", "")
        try:
            path = trusted_operation_location(location, "api.powerbi.com")
            match = re.fullmatch(
                re.escape(urlsplit(url).path) + r"/([0-9a-fA-F-]{36})/?", path,
            )
            if not match:
                raise ValueError("Refresh Location does not identify this workspace/model and a refresh ID.")
            refresh_id = str(UUID(match.group(1)))
        except ValueError as error:
            raise ValueError(f"{name}: refresh response is missing a valid operation Location: {location}") from error
        operation_url = f"{url}/{refresh_id}"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.request("GET", operation_url)
            details = response.json()
            status = details["status"]
            print(f"Semantic model refresh {name}: {status}", flush=True)
            if status == "Completed":
                return
            if status not in {"Unknown", "NotStarted", "InProgress"}:
                raise ValueError(f"Semantic model refresh failed for {name}: {json.dumps(details)}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            delay = max(1, int(response.headers.get("Retry-After", "5")))
            time.sleep(min(delay, remaining))
        raise TimeoutError(
            f"Semantic model refresh timed out for {name} after {timeout} seconds. "
            f"The refresh may still be running; check {operation_url} before retrying."
        )


def validate(manifest: dict, parameters: dict, api: FabricApi, refresh: bool = False) -> None:
    workspace_id = manifest["bi_workspace_id"]
    models = {}
    for item in api.list_items(f"{FABRIC}workspaces/{workspace_id}/items"):
        if item["type"] == "SemanticModel":
            if item["displayName"] in models:
                raise ValueError(f"Ambiguous deployed semantic model: {item['displayName']}")
            models[item["displayName"]] = item["id"]
    for name in manifest["models"]:
        if name not in models:
            raise ValueError(f"Semantic model was not deployed: {name}")
        text = api.model_definition(workspace_id, models[name]).casefold()
        for replacement in manifest["find_replace"]:
            if replacement["item_type"] != "SemanticModel" or replacement["item_name"] != name:
                continue
            source = replacement["find_value"].casefold()
            target = replacement["replace_value"]["_ALL_"]
            if target == "$workspace.$id":
                target = workspace_id
            elif target.startswith("$items.SemanticModel.") and target.endswith(".$id"):
                model_name = target[len("$items.SemanticModel."):-len(".$id")]
                target = models[model_name]
            if target.casefold() not in text or (source != target.casefold() and source in text):
                raise ValueError(f"{name} has an incorrect deployed data/BI reference for {source}.")

    bindings = parameters.get("semantic_model_binding", {}).get("models", [])
    for expected in manifest.get("connections", []):
        matching = [binding for binding in bindings
                    if binding["semantic_model_name"] == expected["semantic_model_name"]]
        if len(matching) != 1:
            raise ValueError(f"{expected['semantic_model_name']} requires exactly one OneLake connection binding.")
        connection_id = matching[0]["connection_id"]["_ALL_"]
        connection = api.request("GET", f"{FABRIC}connections/{connection_id}").json()
        details = connection["connectionDetails"]
        credentials = connection["credentialDetails"]
        if (connection["connectivityType"] != "ShareableCloud"
                or details["type"] != "AzureDataLakeStorage"
                or details["path"].rstrip("/").casefold() != expected["onelake_url"].rstrip("/").casefold()
                or credentials["credentialType"] != "WorkspaceIdentity"
                or credentials["singleSignOnType"] != "None"):
            raise ValueError(f"{expected['semantic_model_name']} must use its target OneLake connection with "
                             "WorkspaceIdentity authentication and SSO disabled.")

    for binding in bindings:
        name = binding["semantic_model_name"]
        expected = binding["connection_id"]["_ALL_"]
        connections = api.list_items(f"{FABRIC}workspaces/{workspace_id}/items/{models[name]}/connections")
        if expected not in {connection["id"] for connection in connections}:
            raise ValueError(f"{name} is not bound to the expected connection {expected}.")
    if manifest["reports"]:
        reports = api.list_items(f"{POWER_BI}groups/{workspace_id}/reports")
        for expected in manifest["reports"]:
            matching = [report for report in reports if report["name"] == expected["name"]]
            if len(matching) != 1 or matching[0].get("datasetId") != models.get(expected["model"]):
                raise ValueError(f"Report {expected['name']} is not linked to BI model {expected['model']}.")

    if refresh:
        for name in manifest["models"]:
            api.refresh_model(workspace_id, models[name], name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--parameters", type=Path, required=True)
    parser.add_argument("--refresh", action="store_true",
                        help="Refresh selected semantic models after validation and wait up to 10 minutes per model.")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    parameters = yaml.safe_load(args.parameters.read_text(encoding="utf-8-sig")) or {}
    validate(manifest, parameters, FabricApi(), refresh=args.refresh)
    print("BI model definitions, connection bindings, and report links validated.")
    if args.refresh:
        print(f"Refresh completed for {len(manifest['models'])} selected semantic models.")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        main()
    except (ValueError, KeyError, TimeoutError, requests.RequestException) as error:
        logging.error("%s", error)
        raise SystemExit(1) from error
