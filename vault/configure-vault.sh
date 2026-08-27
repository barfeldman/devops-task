#!/bin/sh
# Configure HashiCorp Vault for the sample-nodejs app.
#
# Prerequisites (run once, from your workstation):
#   helm repo add hashicorp https://helm.releases.hashicorp.com
#   helm install vault hashicorp/vault -n vault --create-namespace \
#     --set server.standalone.enabled=true --set injector.enabled=false
#   # initialise + unseal (keep the keys somewhere safe, never in Git):
#   kubectl -n vault exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-init.json
#   kubectl -n vault exec vault-0 -- vault operator unseal <unseal-key>
#   # Vault needs to call the TokenReview API for Kubernetes auth:
#   kubectl create clusterrolebinding vault-auth-delegator \
#     --clusterrole=system:auth-delegator --serviceaccount=vault:vault
#   # install the Vault Secrets Operator:
#   helm install vault-secrets-operator hashicorp/vault-secrets-operator \
#     -n vault-secrets-operator-system --create-namespace
#
# Then run this inside the Vault pod with the root token and the desired secret:
#   cat vault/configure-vault.sh | kubectl -n vault exec -i vault-0 -- \
#     env VAULT_TOKEN=<root-token> APP_API_TOKEN=<generated-token> sh -s
set -e
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

# KV v2 store for app secrets.
vault secrets enable -path=secret -version=2 kv 2>/dev/null || echo "kv already enabled"

# Kubernetes auth: pods authenticate with their ServiceAccount token.
vault auth enable kubernetes 2>/dev/null || echo "kubernetes auth already enabled"
vault write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443"

# Least-privilege policy: read only this app's secret.
vault policy write sample-nodejs - <<'EOF'
path "secret/data/sample-nodejs" {
  capabilities = ["read"]
}
EOF

# Bind the policy to the app's ServiceAccount via a Kubernetes auth role.
vault write auth/kubernetes/role/sample-nodejs \
  bound_service_account_names=sample-nodejs \
  bound_service_account_namespaces=sample-nodejs \
  policies=sample-nodejs \
  audience=vault \
  ttl=1h

# Seed the secret. The value comes from the environment - never hard-coded here.
vault kv put secret/sample-nodejs API_TOKEN="${APP_API_TOKEN:?set APP_API_TOKEN}"

echo "Vault configured for sample-nodejs."
