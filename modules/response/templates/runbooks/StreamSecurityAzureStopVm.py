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

def stop_vm_only(vm_id: str, uami_client_id: str):
    subscription_id, resource_group, vm_name, vmss_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    compute_client = ComputeManagementClient(credential, subscription_id)

    try:
        if vmss_name:
            print(f"Stopping VMSS instance '{vm_name}' in scale set '{vmss_name}'")
            operation = compute_client.virtual_machine_scale_set_vms.begin_power_off(
                resource_group_name=resource_group,
                vm_scale_set_name=vmss_name,
                instance_id=vm_name
            )
        else:
            print(f"Stopping VM '{vm_name}'")
            operation = compute_client.virtual_machines.begin_power_off(resource_group, vm_name)

        operation.wait()
        print(f"VM '{vm_name}' has been stopped (but still allocated).")
    except Exception as e:
        raise Exception(f"Failed to stop VM '{vm_name}': {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Missing VM ID argument. Usage: <vm_id> <uami_client_id>")
        sys.exit(1)

    vm_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: Virtual Machine ID: {vm_id}, UAMI Client ID: {uami_client_id}")
    stop_vm_only(vm_id, uami_client_id)
