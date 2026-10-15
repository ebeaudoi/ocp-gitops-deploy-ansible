#!/bin/bash
##############################################################################
# update-values.sh — patch AAP operator + instance "lab" overlay values
#
# This script ONLY edits overlay kustomization.yaml files.
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
#     - Hub disabled (true/false)
#     - Hub file storage StorageClass (used when Hub uses storage_type: file)
#
# Backups are written next to each file as: kustomization.yaml.YYYYMMDD-HHMM
##############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

###############################################################################
# VARIABLES — edit these, then run the script
###############################################################################

# Operator Subscription (operator/overlays/lab/)
CHANNEL="stable-2.7"
CATALOG_SOURCE="redhat-operators"

# Hub settings (instance/overlays/lab/)
# Hub file storage needs ReadWriteMany (RWX). thin-csi is RWO, so Hub is
# disabled by default. Set HUB_DISABLED=false only when you have RWX storage
# or switch the CR to S3 (see ansible/README.md).
HUB_DISABLED="true"
HUB_FILE_STORAGE_CLASS="thin-csi"

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

###############################################################################
# Run
###############################################################################
echo "=========================================="
echo "AAP update-values.sh  (lab overlay)"
echo "  Patches overlays only — does not deploy"
echo "  Backup suffix = .${BACKUP_SUFFIX}"
echo "=========================================="

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
echo "  Hub storage class: ${HUB_FILE_STORAGE_CLASS}"
echo "------------------------------------------"
backup_file "${INSTANCE_OVERLAY}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/disabled" "${HUB_DISABLED}"
echo "    Updated hub.disabled → ${HUB_DISABLED}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/file_storage_storage_class" "${HUB_FILE_STORAGE_CLASS}"
echo "    Updated hub.file_storage_storage_class → ${HUB_FILE_STORAGE_CLASS}"
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
