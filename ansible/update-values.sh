#!/bin/bash
##############################################################################
# update-values.sh — patch AAP operator + instance "lab" overlay values
#
# This script ONLY edits overlay YAML files.
# It does NOT deploy anything to the cluster.
#
# HOW TO USE
#   1. Edit the VARIABLES section below (values you want applied).
#   2. Run from this directory (ansible/) or from the repo root:
#        ./update-values.sh
#        ./ansible/update-values.sh
#
# WHAT IT UPDATES
#   operator/overlays/lab/kustomization.yaml
#     - Subscription channel
#     - CatalogSource name
#   instance/overlays/lab/kustomization.yaml
#     - Hub disabled / storage_type / file StorageClass / S3 Secret name
#   instance/overlays/lab/hub-s3-secret.yaml
#     - Secret name
#     - s3-access-key-id
#     - s3-secret-access-key
#     - s3-bucket-name
#     - s3-region
#     - s3-endpoint
#
# WARNING: Do not commit real S3 credentials. Prefer placeholders in git and
#          apply secrets out-of-band, or keep credentials in a private overlay.
#
# Backups are written next to each file as: <file>.YYYYMMDD-HHMM
##############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

###############################################################################
# VARIABLES — edit these, then run the script
###############################################################################

# -----------------------------------------------------------------------------
# Operator Subscription (operator/overlays/lab/)
# -----------------------------------------------------------------------------
CHANNEL="stable-2.7"
CATALOG_SOURCE="redhat-operators"

# -----------------------------------------------------------------------------
# Hub (instance/overlays/lab/)
#
# storage_type:
#   file  — needs a ReadWriteMany (RWX) StorageClass (thin-csi is RWO → keep Hub disabled)
#   S3    — uses hub-s3-secret.yaml below; no RWX required
#
# To enable Hub with S3:
#   HUB_DISABLED="false"
#   HUB_STORAGE_TYPE="S3"
#   fill in all S3_* values (and HUB_S3_SECRET name)
# -----------------------------------------------------------------------------
HUB_DISABLED="false"
HUB_STORAGE_TYPE="S3"              # file | S3
HUB_FILE_STORAGE_CLASS="thin-csi"    # used when HUB_STORAGE_TYPE=file
HUB_S3_SECRET="aap-hub-s3"           # Secret name + object_storage_s3_secret

# -----------------------------------------------------------------------------
# Hub S3 Secret keys (instance/overlays/lab/hub-s3-secret.yaml)
# All s3-* parameters required by the AAP Hub operator.
#
# AWS: set S3_REGION; leave S3_ENDPOINT as CHANGE_ME or empty if unused.
# S3-compatible (MinIO, etc.): set S3_ENDPOINT to the API URL.
# -----------------------------------------------------------------------------
S3_ACCESS_KEY_ID="s4admin"
S3_SECRET_ACCESS_KEY="s4secret"
S3_BUCKET_NAME="aap-hub-s3"
# S3-compatible (S4/MinIO): use a dummy region + full URL for the endpoint
S3_REGION="us-east-1"
S3_ENDPOINT="http://s4.s4.svc:7480"

###############################################################################
# Helpers (do not edit below)
###############################################################################
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M)"

OPERATOR_OVERLAY="operator/overlays/lab/kustomization.yaml"
INSTANCE_OVERLAY="instance/overlays/lab/kustomization.yaml"
HUB_S3_SECRET_FILE="instance/overlays/lab/hub-s3-secret.yaml"

# Replace the "value:" line that follows a JSON6902 "path: <json_path>" entry.
replace_json6902_value() {
  local file="$1"
  local path="$2"
  local value="$3"
  python3 - "$file" "$path" "$value" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
json_path = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
updated = False
i = 0
while i < len(lines):
    if lines[i].strip() == f"path: {json_path}":
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        if j < len(lines) and lines[j].lstrip().startswith("value:"):
            indent = lines[j][: len(lines[j]) - len(lines[j].lstrip())]
            lines[j] = f"{indent}value: {value}"
            updated = True
            i = j
    i += 1
if not updated:
    raise SystemExit(f"Failed to update path {json_path} in {path}")
path.write_text("\n".join(lines) + "\n")
PY
}

# Replace "key: ..." under a YAML map (first exact key match at any indent).
replace_yaml_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
updated = False
for i, line in enumerate(lines):
    stripped = line.lstrip()
    if stripped.startswith(f"{key}:"):
        indent = line[: len(line) - len(stripped)]
        lines[i] = f"{indent}{key}: {value}"
        updated = True
        break
if not updated:
    raise SystemExit(f"Failed to update key {key} in {path}")
path.write_text("\n".join(lines) + "\n")
PY
}

backup_file() {
  local file="$1"
  cp "${file}" "${file}.${BACKUP_SUFFIX}"
  echo "  Backup: ${file}.${BACKUP_SUFFIX}"
}

validate_hub_settings() {
  case "${HUB_STORAGE_TYPE}" in
    file|S3) ;;
    *)
      echo "ERROR: HUB_STORAGE_TYPE must be 'file' or 'S3' (got: ${HUB_STORAGE_TYPE})"
      exit 1
      ;;
  esac

  if [[ "${HUB_DISABLED}" == "false" && "${HUB_STORAGE_TYPE}" == "file" && "${HUB_FILE_STORAGE_CLASS}" == "thin-csi" ]]; then
    echo "WARNING: Hub enabled with storage_type=file and thin-csi (RWO)."
    echo "         Hub file storage needs RWX, or set HUB_STORAGE_TYPE=S3."
  fi

  if [[ "${HUB_DISABLED}" == "false" && "${HUB_STORAGE_TYPE}" == "S3" ]]; then
    if [[ -z "${HUB_S3_SECRET}" ]]; then
      echo "ERROR: HUB_STORAGE_TYPE=S3 requires HUB_S3_SECRET (Kubernetes Secret name)."
      exit 1
    fi
    local missing=0
    for var in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET_NAME; do
      if [[ -z "${!var}" || "${!var}" == "CHANGE_ME" ]]; then
        echo "ERROR: ${var} must be set (not empty / CHANGE_ME) when enabling Hub with S3."
        missing=1
      fi
    done
    if [[ "${S3_REGION}" == "CHANGE_ME" && "${S3_ENDPOINT}" == "CHANGE_ME" ]]; then
      echo "ERROR: set S3_REGION (AWS) and/or S3_ENDPOINT (S3-compatible) when enabling Hub with S3."
      missing=1
    fi
    if [[ "${missing}" -ne 0 ]]; then
      exit 1
    fi
  fi
}

###############################################################################
# Run
###############################################################################
echo "=========================================="
echo "AAP update-values.sh  (lab overlay)"
echo "  Patches overlays only — does not deploy"
echo "  Backup suffix = .${BACKUP_SUFFIX}"
echo "=========================================="

validate_hub_settings

echo ""
echo "------------------------------------------"
echo "[Operator / lab]"
echo "  File:    ${OPERATOR_OVERLAY}"
echo "  Channel: ${CHANNEL}"
echo "  Catalog: ${CATALOG_SOURCE}"
echo "------------------------------------------"
backup_file "${OPERATOR_OVERLAY}"
replace_json6902_value "${OPERATOR_OVERLAY}" "/spec/channel" "${CHANNEL}"
echo "    Updated channel → ${CHANNEL}"
replace_json6902_value "${OPERATOR_OVERLAY}" "/spec/source" "${CATALOG_SOURCE}"
echo "    Updated catalog → ${CATALOG_SOURCE}"
echo "    Done."

echo ""
echo "------------------------------------------"
echo "[Instance / lab]"
echo "  File:              ${INSTANCE_OVERLAY}"
echo "  Hub disabled:      ${HUB_DISABLED}"
echo "  Hub storage_type:  ${HUB_STORAGE_TYPE}"
echo "  Hub file SC:       ${HUB_FILE_STORAGE_CLASS}"
echo "  Hub S3 Secret:     ${HUB_S3_SECRET}"
echo "------------------------------------------"
backup_file "${INSTANCE_OVERLAY}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/disabled" "${HUB_DISABLED}"
echo "    Updated hub.disabled → ${HUB_DISABLED}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/storage_type" "${HUB_STORAGE_TYPE}"
echo "    Updated hub.storage_type → ${HUB_STORAGE_TYPE}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/file_storage_storage_class" "${HUB_FILE_STORAGE_CLASS}"
echo "    Updated hub.file_storage_storage_class → ${HUB_FILE_STORAGE_CLASS}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/object_storage_s3_secret" "${HUB_S3_SECRET}"
echo "    Updated hub.object_storage_s3_secret → ${HUB_S3_SECRET}"
echo "    Done."

echo ""
echo "------------------------------------------"
echo "[Hub S3 Secret / lab]"
echo "  File:                  ${HUB_S3_SECRET_FILE}"
echo "  name:                  ${HUB_S3_SECRET}"
echo "  s3-access-key-id:      ${S3_ACCESS_KEY_ID}"
echo "  s3-secret-access-key:  ***"
echo "  s3-bucket-name:        ${S3_BUCKET_NAME}"
echo "  s3-region:             ${S3_REGION}"
echo "  s3-endpoint:           ${S3_ENDPOINT}"
echo "------------------------------------------"
backup_file "${HUB_S3_SECRET_FILE}"
replace_yaml_key "${HUB_S3_SECRET_FILE}" "name" "${HUB_S3_SECRET}"
echo "    Updated metadata.name → ${HUB_S3_SECRET}"
replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-access-key-id" "${S3_ACCESS_KEY_ID}"
echo "    Updated s3-access-key-id → ${S3_ACCESS_KEY_ID}"
replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-secret-access-key" "${S3_SECRET_ACCESS_KEY}"
echo "    Updated s3-secret-access-key → ***"
replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-bucket-name" "${S3_BUCKET_NAME}"
echo "    Updated s3-bucket-name → ${S3_BUCKET_NAME}"
replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-region" "${S3_REGION}"
echo "    Updated s3-region → ${S3_REGION}"
replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-endpoint" "${S3_ENDPOINT}"
echo "    Updated s3-endpoint → ${S3_ENDPOINT}"
echo "    Done."

echo ""
echo "=========================================="
echo "Update completed."
echo ""
echo "Next steps (pick one):"
echo "  Manual:   oc apply -k operator/overlays/lab/"
echo "            oc apply -k instance/overlays/lab/"
echo "  Argo CD:  oc apply -k argoCD/   # then sync apps"
echo "=========================================="
