#!/usr/bin/env python3
import re
import sys

from azure.identity import ManagedIdentityCredential
from azure.mgmt.web import WebSiteManagementClient


def parse_vm_id(func_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Web/sites/(?P<func>[^/]+)")
    match = re.match(pattern, func_id)
    if not match:
        raise ValueError(f"Invalid Function App ID format: {func_id}")
    return match.group("sub"), match.group("rg"), match.group("func")

def stop_function_app(function_app_id, uami_client_id: str):
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    subscription_id, resource_group, function_app_name = parse_vm_id(function_app_id)
    client = WebSiteManagementClient(credential, subscription_id)
    try:
        app = client.web_apps.get(resource_group, function_app_name)
        if app.state.lower() == "stopped":
            print(f"Function App '{function_app_name}' is already stopped.")
            return

        print(f"Stopping Function App '{function_app_name}'...")
        client.web_apps.stop(resource_group, function_app_name)
        print(f"Function App '{function_app_name}' has been stopped.")
    except Exception as e:
        raise Exception(f"Failed to stop Function App '{function_app_name}': {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Missing Function App ID argument. Usage: <function_app_id> <uami_client_id>")
        sys.exit(1)
    else:
        function_app_id = sys.argv[1]
        uami_client_id = sys.argv[2]
        print(f"Received Parameters: Function App ID: {function_app_id}, UAMI Client ID: {uami_client_id}")
        stop_function_app(function_app_id, uami_client_id)

