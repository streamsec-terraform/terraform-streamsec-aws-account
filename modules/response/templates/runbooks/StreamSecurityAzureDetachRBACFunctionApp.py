#!/usr/bin/env python3
import re
import sys
import time

from azure.identity import ManagedIdentityCredential
from azure.mgmt.authorization.v2018_09_01_preview import AuthorizationManagementClient
from azure.mgmt.web import WebSiteManagementClient


def parse_function_app_id(func_app_id):
    match = re.match(
        r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/providers/Microsoft.Web/sites/(?P<func>[^/]+)",
        func_app_id
    )
    if not match:
        raise ValueError(f"Invalid Function App ID: {func_app_id}")
    return match.group("sub"), match.group("rg"), match.group("func")


def delete_all_role_assignments_for_principal(principal_id: str, auth_client: AuthorizationManagementClient):
    for assignment in auth_client.role_assignments.list():
        if assignment.principal_id == principal_id:
            try:
                print(f"Deleting role assignment for principal {principal_id}: {assignment.id}")
                auth_client.role_assignments.delete_by_id(assignment.id)
                print(f"Deleted role assignment: {assignment.id}")
            except Exception as e:
                raise Exception(f"Failed to delete {assignment.id}: {e}")


def main(func_app_id, uami_client_id: str):
    subscription_id, resource_group, app_name = parse_function_app_id(func_app_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    web_client = WebSiteManagementClient(credential, subscription_id)
    app = web_client.web_apps.get(resource_group, app_name)
    auth_client = AuthorizationManagementClient(credential, subscription_id)
    identity = app.identity
    if not identity:
        print("No managed identity found.")
        return

    if "SystemAssigned" in identity.type and identity.principal_id:
        print("Deleting role assignments for SystemAssigned identity.")
        delete_all_role_assignments_for_principal(identity.principal_id, auth_client)

    print("Detaching all identities.")
    try:
        web_client.web_apps.update(resource_group, app_name, {
            "identity": {
                "type": "None"
            }
        })
    except Exception as e:
        raise Exception(f"Failed to detach identities: {e}")
    time.sleep(5)
    updated_app = web_client.web_apps.get(resource_group, app_name)
    updated_identity = updated_app.identity
    if updated_identity and updated_identity.type and updated_identity.type != "None":
        raise Exception(f"Validation failed: identity was not properly removed. Found type: {updated_identity.type}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python runbook.py <func_app_id> <uami_client_id>")
        sys.exit(1)

    func_app_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: Function App ID: {func_app_id}, UAMI Client ID: {uami_client_id}")
    main(func_app_id, uami_client_id)

