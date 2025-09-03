#!/usr/bin/env python3

import sys
import requests
from azure.identity import ManagedIdentityCredential

GRAPH_ENDPOINT = "https://graph.microsoft.com/v1.0"

def disable_user_account(user_id: str, uami_client_id:str):
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    token = credential.get_token("https://graph.microsoft.com/.default")
    headers = {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json"
    }

    url = f"{GRAPH_ENDPOINT}/users/{user_id}"
    body = {
        "accountEnabled": False
    }

    try:
        print(f"Disabling user account for ID: {user_id}")
        response = requests.patch(url, headers=headers, json=body)
        if response.status_code == 204:
            print(f"User {user_id} has been disabled successfully.")
        else:
            raise Exception(f"Failed to disable user {user_id}. "
                            f"Status: {response.status_code}, Response: {response.text}")
    except Exception as e:
        raise Exception(f"Error disabling user account: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: disable_user.py <user_id><uami_client_id>")
        sys.exit(1)

    user_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: User ID: {user_id}, UAMI Client ID: {uami_client_id}")
    disable_user_account(user_id, uami_client_id)

