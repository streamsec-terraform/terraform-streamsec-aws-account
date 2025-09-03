#!/usr/bin/env python3

import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.storage import StorageManagementClient
from azure.storage.blob import BlobServiceClient, AccessPolicy


def parse_storage_account_id(account_id):
    match = re.match(
        r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/providers/Microsoft.Storage/storageAccounts/(?P<account>[^/]+)",
        account_id
    )
    if not match:
        raise ValueError(f"Invalid storage account ID: {account_id}")
    return match.group("sub"), match.group("rg"), match.group("account")

def disable_public_access(account_id: str, uami_client_id: str):
    subscription_id, resource_group, account_name = parse_storage_account_id(account_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)

    print(f"Disabling account-level public access for storage account: {account_name}")
    storage_client = StorageManagementClient(credential, subscription_id)
    try:
        storage_client.storage_accounts.update(
            resource_group_name=resource_group,
            account_name=account_name,
            parameters={"allow_blob_public_access": False}
        )
        print(f"Account-level public access disabled for: {account_name}")
    except Exception as e:
        raise Exception(f"Failed to disable account-level public access: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: disable_storage_account_public_access.py <storage_account_id> <uami_client_id>")
        sys.exit(1)

    account_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: Storage Account ID: {account_id} UAMI Client ID: {uami_client_id}")
    disable_public_access(account_id, uami_client_id)
