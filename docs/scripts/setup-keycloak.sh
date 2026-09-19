#!/usr/bin/env bash
# Creates the Keycloak objects the EazyBank gateway expects (local dev Keycloak only):
#   realm roles ACCOUNTS, CARDS, LOANS and a service-account client "eazybank-callcenter-cc"
# with secret "eazybank-secret" holding all three roles. Safe to re-run.
set -euo pipefail
KC=${KC:-http://localhost:7080}
CLIENT=eazybank-callcenter-cc
SECRET=eazybank-secret

TOKEN=$(curl -s -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  "$KC/realms/master/protocol/openid-connect/token" | python -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
ADMIN="$KC/admin/realms/master"

for r in ACCOUNTS CARDS LOANS; do
  curl -s -o /dev/null "${AUTH[@]}" -X POST "$ADMIN/roles" -d "{\"name\":\"$r\"}" || true
done

curl -s -o /dev/null "${AUTH[@]}" -X POST "$ADMIN/clients" -d "{
  \"clientId\":\"$CLIENT\",\"secret\":\"$SECRET\",\"serviceAccountsEnabled\":true,
  \"publicClient\":false,\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false}" || true

ID=$(curl -s "${AUTH[@]}" "$ADMIN/clients?clientId=$CLIENT" | python -c "import json,sys;print(json.load(sys.stdin)[0]['id'])")
SA=$(curl -s "${AUTH[@]}" "$ADMIN/clients/$ID/service-account-user" | python -c "import json,sys;print(json.load(sys.stdin)['id'])")
ROLES=$(for r in ACCOUNTS CARDS LOANS; do curl -s "${AUTH[@]}" "$ADMIN/roles/$r"; echo; done | python -c "import sys,json;print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))")
curl -s -o /dev/null "${AUTH[@]}" -X POST "$ADMIN/users/$SA/role-mappings/realm" -d "$ROLES"
echo "Done. Get a token with:"
echo "  curl -s -d grant_type=client_credentials -d client_id=$CLIENT -d client_secret=$SECRET $KC/realms/master/protocol/openid-connect/token"
