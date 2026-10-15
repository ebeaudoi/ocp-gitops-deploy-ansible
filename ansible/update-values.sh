#!/bin/bash
##############################################################################
# update-values.sh — patch AAP operator + instance "lab" overlay values
#
# This script ONLY edits overlay kustomization.yaml files.
# It does NOT deploy anything to the cluster.
# It does NOT create the S3 credentials Secret (create that with oc separately).
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
#     - Hub disabled (true/false)
#     - Hub storage_type (file | S3)
#     - Hub file StorageClass (when storage_type=file)
#     - Hub S3 Secret name (when storage_type=S3)
#
# Backups are written next to each file as: kustomization.yaml.YYYYMMDD-HHMM
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
#   S3    — needs a Secret in ansible-automation-platform (see below); no RWX required
#
# To enable Hub with S3:
#   HUB_DISABLED="false"
#   HUB_STORAGE_TYPE="S3"
#   HUB_S3_SECRET="aap-hub-s3"   # must match an existing Secret in the AAP namespace
#
# Create the Secret once (not managed by this script), for example:
#   oc -n ansible-automation-platform apply -f- <<EOF
#   apiVersion: v1
#   kind: Secret
#   metadata:
#     name: aap-hub-s3
#   stringData:
#     s3-access-key-id: <ACCESS_KEY>
#     s3-secret-access-key: <SECRET_KEY>
#     s3-bucket-name: <BUCKET>
#     s3-region: <REGION>                 # AWS
#     # s3-endpoint: https://minio.example/  # S3-compatible (MinIO, etc.)
#   EOF
# -----------------------------------------------------------------------------
HUB_DISABLED="true"
HUB_STORAGE_TYPE="file"              # file | S3
HUB_FILE_STORAGE_CLASS="thin-csi"    # used when HUB_STORAGE_TYPE=file
HUB_S3_SECRET="aap-hub-s3"           # used when HUB_STORAGE_TYPE=S3

###############################################################################
# Helpers (do not edit below)
###############################################################################
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M)"

OPERATOR_OVERLAY="operator/overlays/lab/kustomization.yaml"
INSTANCE_OVERLAY="instance/overlays/lab/kustomization.yaml"

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

  if [[ "${HUB_DISABLED}" == "false" && "${HUB_STORAGE_TYPE}" == "S3" && -z "${HUB_S3_SECRET}" ]]; then
    echo "ERROR: HUB_STORAGE_TYPE=S3 requires HUB_S3_SECRET (Kubernetes Secret name)."
    exit 1
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
echo "=========================================="
echo "Update completed."
if [[ "${HUB_STORAGE_TYPE}" == "S3" && "${HUB_DISABLED}" == "false" ]]; then
  echo ""
  echo "Remember: create Secret '${HUB_S3_SECRET}' in ansible-automation-platform"
  echo "before syncing the instance (keys: s3-access-key-id, s3-secret-access-key,"
  echo "s3-bucket-name, and s3-region or s3-endpoint)."
fi
echo ""
echo "Next steps (pick one):"
echo "  Manual:   oc apply -k operator/overlays/lab/"
echo "            oc apply -k instance/overlays/lab/"
echo "  Argo CD:  oc apply -k argoCD/   # then sync apps"
echo "=========================================="
