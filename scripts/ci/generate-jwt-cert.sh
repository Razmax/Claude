#!/usr/bin/env bash
#
# Generates the key pair used for Salesforce JWT authentication from CI.
#
#   ./scripts/ci/generate-jwt-cert.sh qa
#   ./scripts/ci/generate-jwt-cert.sh prod
#
# Upload the .crt to the connected app in that org; put the base64 of the .key
# into the matching GitHub secret. Use a SEPARATE key pair per org so that
# rotating or revoking QA access never touches production.
#
# The generated files are secrets. They are written to ./.jwt-keys/, which is
# gitignored, and they should be deleted once the GitHub secret is set.

set -euo pipefail

ORG_LABEL="${1:-}"
if [ -z "$ORG_LABEL" ]; then
    echo "Usage: $0 <org-label>    e.g. $0 qa" >&2
    exit 1
fi

OUT_DIR=".jwt-keys"
KEY_FILE="${OUT_DIR}/${ORG_LABEL}-server.key"
CRT_FILE="${OUT_DIR}/${ORG_LABEL}-server.crt"

if [ -e "$KEY_FILE" ]; then
    echo "ERROR: $KEY_FILE already exists. Delete it first if you really mean to rotate the key." >&2
    echo "Rotating means re-uploading the new certificate to the connected app as well." >&2
    exit 1
fi

umask 077
mkdir -p "$OUT_DIR"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY_FILE"
openssl req -new -x509 -nodes -sha256 -days 3650 \
    -key "$KEY_FILE" \
    -out "$CRT_FILE" \
    -subj "/CN=salesforce-ci-${ORG_LABEL}"

chmod 600 "$KEY_FILE"

cat <<SUMMARY

Generated for "${ORG_LABEL}":
  certificate : ${CRT_FILE}   -> upload to the connected app (Use digital signatures)
  private key : ${KEY_FILE}   -> becomes the GitHub secret below

Set the GitHub secret with the base64 of the private key:

  gh secret set SF_$(echo "$ORG_LABEL" | tr '[:lower:]' '[:upper:]')_JWT_KEY < <(base64 -w0 "${KEY_FILE}")

(on macOS, base64 has no -w flag: use  base64 -i "${KEY_FILE}" )

Once the secret is set and a workflow run has authenticated successfully,
delete the local copies:

  rm -rf ${OUT_DIR}

SUMMARY
