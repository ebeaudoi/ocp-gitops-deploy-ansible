#!/bin/bash
##############################################################################
# update-values.sh — patch AAP operator + instance overlay values
#
# This script ONLY edits overlay kustomization.yaml files.
# It does NOT deploy anything to the cluster.
#
# HOW TO USE
#   1. Edit the VARIABLES sections below (values you want applied).
#   2. Set UPDATE_CONNECTED / UPDATE_AIRGAPPED to true for overlays to refresh.
#   3. Run from this directory (ansible/) or from the repo root:
#        ./update-values.sh
#        ./ansible/update-values.sh
#
# WHAT IT UPDATES
#   operator/overlays/{connected,airgapped}/kustomization.yaml
#     - Subscription channel
#     - CatalogSource name
#     - InstallPlan approval (airgapped only)
#   instance/overlays/{connected,airgapped}/kustomization.yaml
#     - Hub disabled (true/false)
#     - Hub file storage StorageClass (used when Hub uses storage_type: file)
#
# Backups are written next to each file as: kustomization.yaml.YYYYMMDD-HHMM
##############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

###############################################################################
# TOGGLE — which overlays to update (true / false)
###############################################################################
UPDATE_CONNECTED=true
UPDATE_AIRGAPPED=true

###############################################################################
# OPERATOR — CONNECTED
# Path: operator/overlays/connected/
# Online cluster using the Red Hat Operators catalog.
###############################################################################
CONNECTED_CHANNEL="stable-2.7"
CONNECTED_CATALOG_SOURCE="redhat-operators"

###############################################################################
# OPERATOR — AIRGAPPED
# Path: operator/overlays/airgapped/
# Disconnected cluster using a mirrored catalog + Manual InstallPlan.
###############################################################################
AIRGAPPED_CHANNEL="stable-2.7"
AIRGAPPED_CATALOG_SOURCE="ebdn-redhat-operators"
AIRGAPPED_INSTALL_PLAN_APPROVAL="Manual"

###############################################################################
# INSTANCE — HUB (applied to both overlays when their UPDATE_* toggle is true)
# Path: instance/overlays/{connected,airgapped}/
#
# Hub file storage needs ReadWriteMany (RWX). thin-csi is RWO, so Hub is
# disabled by default. Set HUB_DISABLED=false only when you have RWX storage
# or switch the CR to S3 (see ansible/README.md).
###############################################################################
HUB_DISABLED="true"
HUB_FILE_STORAGE_CLASS="thin-csi"

###############################################################################
# Helpers (do not edit below)
###############################################################################
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M)"

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

update_operator_overlay() {
  local kind="$1"       # connected | airgapped
  local channel="$2"
  local catalog="$3"
  local approval="${4:-}"  # optional (airgapped only)

  local file="operator/overlays/${kind}/kustomization.yaml"

  echo ""
  echo "------------------------------------------"
  echo "[Operator / ${kind}]"
  echo "  File:     ${file}"
  echo "  Channel:  ${channel}"
  echo "  Catalog:  ${catalog}"
  if [[ -n "${approval}" ]]; then
    echo "  Approval: ${approval}"
  fi
  echo "------------------------------------------"

  backup_file "${file}"
  replace_json6902_value "${file}" "/spec/channel" "${channel}"
  echo "    Updated channel → ${channel}"
  replace_json6902_value "${file}" "/spec/source" "${catalog}"
  echo "    Updated catalog → ${catalog}"

  if [[ -n "${approval}" ]]; then
    replace_json6902_value "${file}" "/spec/installPlanApproval" "${approval}"
    echo "    Updated installPlanApproval → ${approval}"
  fi

  echo "    Done."
}

update_instance_overlay() {
  local kind="$1"   # connected | airgapped

  local file="instance/overlays/${kind}/kustomization.yaml"

  echo ""
  echo "------------------------------------------"
  echo "[Instance / ${kind}]"
  echo "  File:              ${file}"
  echo "  Hub disabled:      ${HUB_DISABLED}"
  echo "  Hub storage class: ${HUB_FILE_STORAGE_CLASS}"
  echo "------------------------------------------"

  backup_file "${file}"
  replace_json6902_value "${file}" "/spec/hub/disabled" "${HUB_DISABLED}"
  echo "    Updated hub.disabled → ${HUB_DISABLED}"
  replace_json6902_value "${file}" "/spec/hub/file_storage_storage_class" "${HUB_FILE_STORAGE_CLASS}"
  echo "    Updated hub.file_storage_storage_class → ${HUB_FILE_STORAGE_CLASS}"

  echo "    Done."
}

###############################################################################
# Run
###############################################################################
echo "=========================================="
echo "AAP update-values.sh"
echo "  Patches overlays only — does not deploy"
echo "------------------------------------------"
echo "  UPDATE_CONNECTED = ${UPDATE_CONNECTED}"
echo "  UPDATE_AIRGAPPED = ${UPDATE_AIRGAPPED}"
echo "  Backup suffix    = .${BACKUP_SUFFIX}"
echo "=========================================="

if [[ "${UPDATE_CONNECTED}" != "true" && "${UPDATE_AIRGAPPED}" != "true" ]]; then
  echo "Nothing to do: set UPDATE_CONNECTED and/or UPDATE_AIRGAPPED to true."
  exit 0
fi

if [[ "${UPDATE_CONNECTED}" == "true" ]]; then
  update_operator_overlay connected \
    "${CONNECTED_CHANNEL}" \
    "${CONNECTED_CATALOG_SOURCE}"
  update_instance_overlay connected
fi

if [[ "${UPDATE_AIRGAPPED}" == "true" ]]; then
  update_operator_overlay airgapped \
    "${AIRGAPPED_CHANNEL}" \
    "${AIRGAPPED_CATALOG_SOURCE}" \
    "${AIRGAPPED_INSTALL_PLAN_APPROVAL}"
  update_instance_overlay airgapped
fi

echo ""
echo "=========================================="
echo "Update completed."
echo ""
echo "Next steps (pick one):"
echo "  Manual:   oc apply -k operator/overlays/<overlay>/"
echo "            oc apply -k instance/overlays/<overlay>/"
echo "  Argo CD:  oc apply -k argoCD/   # then sync apps"
echo "=========================================="
