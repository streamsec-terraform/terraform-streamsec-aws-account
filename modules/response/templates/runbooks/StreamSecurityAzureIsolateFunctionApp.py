#!/usr/bin/env python3
import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.web import WebSiteManagementClient

def parse_function_app_id(app_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Web/sites/(?P<app>[^/]+)")
    match = re.match(pattern, app_id)
    if not match:
        raise ValueError(f"Invalid Function App ID format: {app_id}")
    return match.group("sub"), match.group("rg"), match.group("app")


def isolate_function_app(app_id, uami_client_id):
    subscription_id, resource_group, app_name = parse_function_app_id(app_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    web_client = WebSiteManagementClient(credential, subscription_id)

    print("Disabling public network access...")
    site_config = {
        "public_network_access": "Disabled"
    }
    try:
        web_client.web_apps.update_configuration(resource_group, app_name, site_config)
    except Exception as e:
        raise Exception(f"Failed to disable public network access: {e}")
    print("Public network access disabled.")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python isolate_function_app.py <function_app_id> <uami_client_id>")
        sys.exit(1)

    app_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: Function App ID: {app_id}, UAMI Client ID: {uami_client_id}")
    isolate_function_app(app_id, uami_client_id)
