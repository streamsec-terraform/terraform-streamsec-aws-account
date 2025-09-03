#!/usr/bin/env python3
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient

def parse_vmss_id(vmss_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/providers/"
               r"Microsoft.Compute/virtualMachineScaleSets/(?P<vmss>[^/]+)")
    match = re.match(pattern, vmss_id)
    if not match:
        raise ValueError(f"Invalid VMSS ID format: {vmss_id}")
    return match.group("sub"), match.group("rg"), match.group("vmss")

def protect_vmss_instance(vm_name, vmss_id, uami_client_id: str):
    subscription_id, resource_group, vmss_name = parse_vmss_id(vmss_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    compute_client = ComputeManagementClient(credential, subscription_id)
    vmss = compute_client.virtual_machine_scale_sets.get(resource_group, vmss_name)
    update_params = {
    "protection_policy": {
        "protect_from_scale_in": True,
        "protect_from_scale_set_actions": True
    }
    }
    mode = (vmss.orchestration_mode or "Uniform").lower()
    if mode == "uniform":
        if '_' in vm_name:
            vm_name = vm_name.split('_')[-1]

    print(f"Setting protection on VMSS instance Name '{vm_name}'...")
    try:
        poller = compute_client.virtual_machine_scale_set_vms.begin_update(
            resource_group_name=resource_group,
            vm_scale_set_name=vmss_name,
            instance_id=vm_name,
            parameters=update_params
        )
        poller.result()
        print(f"Protection set on instance '{vm_name}' in {mode} scale set '{vmss_name}'.")
    except Exception as e:
        raise Exception(f"Failed to set protection on instance '{vm_name}' in scale set '{vmss_name}': {e}")


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 4:
        print("Missing arguments. Usage: <vm_name> <vmss_id> <uami_client_id>")
        sys.exit(1)
    vm_name = sys.argv[1]
    vmss_id = sys.argv[2]

    uami_client_id = sys.argv[3]
    print(f"Received Parameters: VM Name: {vm_name}, VMSS ID: {vmss_id}, UAMI Client ID: {uami_client_id}")
    protect_vmss_instance(vm_name, vmss_id, uami_client_id)

