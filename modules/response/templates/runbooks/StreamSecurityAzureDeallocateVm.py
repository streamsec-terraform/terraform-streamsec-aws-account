#!/usr/bin/env python3

import re
import sys
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient

def parse_vm_id(vm_id):
    if "/virtualMachineScaleSets/" in vm_id:
        pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
                   r"providers/Microsoft\.Compute/virtualMachineScaleSets/(?P<vmss>[^/]+)/"
                   r"virtualMachines/(?P<vm>[^/]+)")
        match = re.match(pattern, vm_id, re.IGNORECASE)
        if not match:
            raise ValueError(f"Invalid VMSS VM ID format: {vm_id}")
        return match.group("sub"), match.group("rg"), match.group("vm"), match.group("vmss")
    else:
        pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
                   r"providers/Microsoft\.Compute/virtualMachines/(?P<vm>[^/]+)")
        match = re.match(pattern, vm_id, re.IGNORECASE)
        if not match:
            raise ValueError(f"Invalid VM ID format: {vm_id}")
        return match.group("sub"), match.group("rg"), match.group("vm"), None

def stop_and_deallocate_vm(vm_id: str, uami_client_id: str):
    subscription_id, resource_group, vm_name, vmss_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    compute_client = ComputeManagementClient(credential, subscription_id)

    try:
        if vmss_name:
            print(f"Deallocating VMSS instance '{vm_name}' in scale set '{vmss_name}'...")
            operation = compute_client.virtual_machine_scale_set_vms.begin_deallocate(
                resource_group_name=resource_group,
                vm_scale_set_name=vmss_name,
                instance_id=vm_name
            )
        else:
            print(f"Deallocating regular VM '{vm_name}'...")
            operation = compute_client.virtual_machines.begin_deallocate(
                resource_group_name=resource_group,
                vm_name=vm_name
            )
        operation.wait()
    except Exception as e:
        raise Exception(f"Failed to stop and deallocate VM '{vm_name}': {e}")
    print(f"VM '{vm_name}' has been stopped and deallocated.")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python runbook.py <vm_id> <uami_client_id>")
        sys.exit(1)

    vm_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: VM ID: {vm_id}, UAMI Client ID: {uami_client_id}")
    stop_and_deallocate_vm(vm_id, uami_client_id)
