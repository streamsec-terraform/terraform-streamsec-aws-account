#!/usr/bin/env python3
import re
import sys
from azure.identity import ManagedIdentityCredential
from azure.mgmt.authorization.v2018_09_01_preview import AuthorizationManagementClient
from azure.mgmt.compute import ComputeManagementClient


def parse_vm_id(vm_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Compute/virtualMachines/(?P<vm>[^/]+)")
    match = re.match(pattern, vm_id)
    if not match:
        raise ValueError(f"Invalid VM ID format: {vm_id}")
    return match.group("sub"), match.group("rg"), match.group("vm")


def delete_all_role_assignments(principal_id: str, vm_id: str, auth_client: AuthorizationManagementClient):
    for assignment in auth_client.role_assignments.list():
        if assignment.principal_id == principal_id:
            try:
                print(f"Deleting role assignment for principal {principal_id}: {assignment.id}")
                auth_client.role_assignments.delete_by_id(assignment.id)
                print(f"Deleted role assignment: {assignment.id}")
            except Exception as e:
                raise Exception(f"Failed to delete {assignment.id}: {e}")


def main(vm_id, uami_client_id: str):
    subscription_id, resource_group, vm_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    compute_client = ComputeManagementClient(credential, subscription_id)
    auth_client = AuthorizationManagementClient(credential, subscription_id)
    vm = compute_client.virtual_machines.get(resource_group, vm_name)
    identity = vm.identity

    if not identity:
        print("No managed identity found.")
    else:
        if "SystemAssigned" in identity.type and identity.principal_id:
            delete_all_role_assignments(identity.principal_id, vm_id, auth_client)

        try:
            print("Detaching identities from the VM...")
            poller = compute_client.virtual_machines.begin_update(resource_group, vm_name, {
                "identity": {
                        "type": "None"
                    }
            })
            poller.result()
        except Exception as e:
            raise Exception(f"Failed to detach identities: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python runbook.py <vm_id> <uami_client_id>")
        sys.exit(1)

    vm_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: VM ID: {vm_id}, UAMI Client ID: {uami_client_id}")
    main(vm_id, uami_client_id)
