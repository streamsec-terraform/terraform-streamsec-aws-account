#!/usr/bin/env python3

import sys
import requests
from azure.identity import ManagedIdentityCredential

GRAPH_ENDPOINT = "https://graph.microsoft.com/v1.0"

def revoke_user_sessions(user_id: str, uami_client_id: str):
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    token = credential.get_token("https://graph.microsoft.com/.default")
    headers = {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json"
    }

    url = f"{GRAPH_ENDPOINT}/users/{user_id}/revokeSignInSessions"

    try:
        print(f"Revoking sessions for user ID: {user_id}")
        response = requests.post(url, headers=headers)
        if response.status_code == 200 and response.json().get("value") == True:
            print(f"User {user_id} sessions revoked successfully.")
        else:
            raise Exception(f"Failed to revoke sessions for user {user_id}. "
                            f"Status: {response.status_code}, Response: {response.text}"
                            f"This may fail if the user has privileged roles (e.g., admin) or if the managed identity lacks sufficient Graph API permissions.")
    except Exception as e:
        raise Exception(f"Error revoking user sessions: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: revoke_user_sessions.py <user_id> <uami_client_id>")
        sys.exit(1)

    user_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: User ID: {user_id}, UAMI Client ID: {uami_client_id}")
    revoke_user_sessions(user_id, uami_client_id)
