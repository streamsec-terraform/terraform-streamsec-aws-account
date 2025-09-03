#!/usr/bin/env python3
import re
import sys
from azure.identity import ManagedIdentityCredential
from azure.mgmt.web import WebSiteManagementClient

def parse_function_app_id(func_app_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Web/sites/(?P<func>[^/]+)")
    match = re.match(pattern, func_app_id)
    if not match:
        raise ValueError(f"Invalid Function App ID format: {func_app_id}")
    return match.group("sub"), match.group("rg"), match.group("func")

def disable_function_triggers(func_app_id, uami_client_id: str):
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    subscription_id, resource_group, function_app_name = parse_function_app_id(func_app_id)
    client = WebSiteManagementClient(credential, subscription_id)
    try:
        config = client.web_apps.list_application_settings(resource_group, function_app_name)
        settings = config.properties
        key = f"AzureWebJobs.{function_app_name}.Disabled"
        if key in settings and settings[key].lower() == "true":
            raise Exception(f"Function triggers for '{function_app_name}' are already disabled.")
        settings[key] = "true"

        print("Updating app settings...")
        client.web_apps.update_application_settings(
            resource_group, function_app_name, {"properties": settings}
        )
        print("Selected function trigger(s) have been disabled.")
    except Exception as e:
        raise Exception(f"Failed to disable function triggers for '{function_app_name}': {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python runbook.py <func_app_id> <uami_client_id>")
        sys.exit(1)

    func_app_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: Function App ID: {func_app_id}, UAMI Client ID: {uami_client_id}")
    disable_function_triggers(func_app_id, uami_client_id)
