#!/usr/bin/env python3
import sys
import re
import datetime
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.compute.models import Snapshot

def parse_vm_id(vm_id: str):
    if "/virtualmachinescalesets/" in vm_id.lower():
        pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
                   r"providers/Microsoft.Compute/virtualMachineScaleSets/(?P<vmss>[^/]+)/"
                   r"virtualMachines/(?P<vm>[^/]+)")
        match = re.match(pattern, vm_id, re.IGNORECASE)
        if not match:
            raise ValueError(f"Invalid VMSS VM ID format: {vm_id}")
        return match.group("sub"), match.group("rg"), match.group("vm"), match.group("vmss")
    else:
        pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
                   r"providers/Microsoft.Compute/virtualMachines/(?P<vm>[^/]+)")
        match = re.match(pattern, vm_id, re.IGNORECASE)
        if not match:
            raise ValueError(f"Invalid VM ID format: {vm_id}")
        return match.group("sub"), match.group("rg"), match.group("vm"), None

def create_snapshot(client, resource_group, location, disk_id, name):
    if not disk_id:
        return
    config = Snapshot(
        location=location,
        creation_data={"create_option": "Copy", "source_resource_id": disk_id}
    )
    print(f"Creating snapshot '{name}'...")
    try:
        snapshot = client.snapshots.begin_create_or_update(resource_group, name, config).result()
    except Exception as e:
        raise Exception(f"Failed to create snapshot '{name}': {e}")
    print(f"Snapshot '{snapshot.name}' created.")

def snapshot_from_vm(vm_id: str, location: str, uami_client_id: str):
    sub_id, rg, vm_name, vmss_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    compute_client = ComputeManagementClient(credential, sub_id)
    timestamp = datetime.datetime.utcnow().strftime("%Y%m%d%H%M%S")

    if vmss_name:
        print(f"Fetching VMSS instance '{vm_name}' in scale set '{vmss_name}'...")
        vm = compute_client.virtual_machine_scale_set_vms.get(rg, vmss_name, vm_name)
    else:
        print(f"Fetching regular VM '{vm_name}'...")
        vm = compute_client.virtual_machines.get(rg, vm_name)

    # Snapshot OS disk
    os_disk = vm.storage_profile.os_disk
    if os_disk and os_disk.managed_disk and os_disk.managed_disk.id:
        create_snapshot(compute_client, rg, location, os_disk.managed_disk.id, f"{vm_name}-osdisk-snapshot-{timestamp}")

    # Snapshot data disks
    data_disks = vm.storage_profile.data_disks or []
    for i, disk in enumerate(data_disks):
        if disk.managed_disk and disk.managed_disk.id:
            create_snapshot(compute_client, rg, location, disk.managed_disk.id, f"{vm_name}-datadisk{i}-snapshot-{timestamp}")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Missing arguments. Usage: <vm_id> <location> <uami_client_id> [<os_disk_id>]")
        sys.exit(1)

    vm_id = sys.argv[1]
    location = sys.argv[2]
    uami_client_id = sys.argv[3]

    print(f"Received Parameters: VM ID: {vm_id}, Location: {location}, UAMI Client ID: {uami_client_id}")
    snapshot_from_vm(vm_id, location, uami_client_id)
