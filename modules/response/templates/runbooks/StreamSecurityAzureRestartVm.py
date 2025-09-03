#!/usr/bin/env python3
import re
from azure.mgmt.compute import ComputeManagementClient
from azure.identity import ManagedIdentityCredential


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


def runbook_main(vm_id: str, uami_client_id: str):
    subscription_id, resource_group_name, vm_name, vmss_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)

    compute_client = ComputeManagementClient(credential, subscription_id)

    try:
        if vmss_name:
            print(f"Restarting VMSS instance: {vm_name} in scale set: {vmss_name}")
            restart_operation = compute_client.virtual_machine_scale_set_vms.begin_restart(
                resource_group_name=resource_group_name,
                vm_scale_set_name=vmss_name,
                instance_id=vm_name
            )
        else:
            print(f"Restarting VM: {vm_name} in resource group: {resource_group_name}")
            restart_operation = compute_client.virtual_machines.begin_restart(
                resource_group_name, vm_name)

        restart_operation.wait()
        print(f"VM '{vm_name}' restarted successfully.")
    except Exception as e:
        raise Exception(f"Failed to restart VM '{vm_name}': {e}")


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3:
        print("Usage: python runbook.py <vm_id> <uami_client_id>")
        sys.exit(1)

    vm_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: VM ID: {vm_id}, UAMI Client ID: {uami_client_id}")
    runbook_main(vm_id, uami_client_id)
