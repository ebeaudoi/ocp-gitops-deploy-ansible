#!/bin/bash
##############################################################################
# update-values.sh — patch AAP operator + instance "lab" overlay values
#
# This script ONLY edits overlay/base YAML files.
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
#   operator/base/namespace.yaml
#   operator/base/subscription.yaml
#   instance/base/ansible-automation-platform.yaml
#     - Infra nodeSelector + tolerations (Namespace, Subscription, AAP CR)
#   instance/overlays/lab/kustomization.yaml
#     - Hub disabled / storage_type / file StorageClass / file size / S3 Secret name
#     - Lightspeed disabled (true|false)
#   instance/overlays/lab/hub-s3-secret.yaml
#   s3-validate/overlays/lab/hub-s3-secret.yaml
#     - Secret name + all s3-* keys (kept in sync for AAP Hub + validate Job)
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
# Infra node placement (Namespace + Subscription + AAP CR components)
#
# OpenShift infra nodes typically use an empty-value role label and matching
# taints. Tolerations use operator=Exists for each effect listed below.
#
# Examples:
#   INFRA_NODE_KEY="node-role.kubernetes.io/infra"
#   INFRA_NODE_VALUE=""
#   INFRA_TOLERATION_EFFECTS="NoSchedule,NoExecute"
# -----------------------------------------------------------------------------
INFRA_NODE_KEY="node-role.kubernetes.io/infra"
INFRA_NODE_VALUE=""
INFRA_TOLERATION_EFFECTS="NoSchedule,NoExecute"

# -----------------------------------------------------------------------------
# Hub (instance/overlays/lab/)
#
# storage_type:
#   file  — needs a ReadWriteMany (RWX) StorageClass (NOT thin-csi / RWO)
#   S3    — uses hub-s3-secret.yaml below; no RWX required
#
# To enable Hub with file (RWX PVC):
#   HUB_DISABLED="false"
#   HUB_STORAGE_TYPE="file"
#   HUB_FILE_STORAGE_CLASS="<rwx-storageclass>"   # e.g. ocs-storagecluster-cephfs
#   HUB_FILE_STORAGE_SIZE="10Gi"
#
# To enable Hub with S3:
#   HUB_DISABLED="false"
#   HUB_STORAGE_TYPE="S3"
#   fill in all S3_* values (and HUB_S3_SECRET name)
# -----------------------------------------------------------------------------
HUB_DISABLED="false"
HUB_STORAGE_TYPE="S3"                # file | S3
HUB_FILE_STORAGE_CLASS="thin-csi"    # RWX class when HUB_STORAGE_TYPE=file
HUB_FILE_STORAGE_SIZE="10Gi"         # PVC size when HUB_STORAGE_TYPE=file
HUB_S3_SECRET="aap-hub-s3"           # Secret name + object_storage_s3_secret

# -----------------------------------------------------------------------------
# Lightspeed (instance/overlays/lab/kustomization.yaml)
#   true  — leave Ansible Lightspeed disabled (default)
#   false — enable Lightspeed
# -----------------------------------------------------------------------------
LIGHTSPEED_DISABLED="false"

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
#S3_ENDPOINT="https://s3.s4.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"
S3_ENDPOINT="http://s4.s4.svc:7480"
###############################################################################
# Helpers (do not edit below)
###############################################################################
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M)"

OPERATOR_OVERLAY="operator/overlays/lab/kustomization.yaml"
INSTANCE_OVERLAY="instance/overlays/lab/kustomization.yaml"
OPERATOR_NAMESPACE="operator/base/namespace.yaml"
OPERATOR_SUBSCRIPTION="operator/base/subscription.yaml"
INSTANCE_AAP_CR="instance/base/ansible-automation-platform.yaml"
# Instance (AAP Hub) + s3-validate Job share the same credential values
HUB_S3_SECRET_FILES=(
  "instance/overlays/lab/hub-s3-secret.yaml"
  "s3-validate/overlays/lab/hub-s3-secret.yaml"
)

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

  case "${HUB_DISABLED}" in
    true|false) ;;
    *)
      echo "ERROR: HUB_DISABLED must be 'true' or 'false' (got: ${HUB_DISABLED})"
      exit 1
      ;;
  esac

  case "${LIGHTSPEED_DISABLED}" in
    true|false) ;;
    *)
      echo "ERROR: LIGHTSPEED_DISABLED must be 'true' or 'false' (got: ${LIGHTSPEED_DISABLED})"
      exit 1
      ;;
  esac

  if [[ -z "${INFRA_NODE_KEY}" ]]; then
    echo "ERROR: INFRA_NODE_KEY must not be empty."
    exit 1
  fi

  if [[ -z "${INFRA_TOLERATION_EFFECTS}" ]]; then
    echo "ERROR: INFRA_TOLERATION_EFFECTS must not be empty (e.g. NoSchedule,NoExecute)."
    exit 1
  fi

  IFS=',' read -r -a _effects <<< "${INFRA_TOLERATION_EFFECTS}"
  for effect in "${_effects[@]}"; do
    effect="$(echo "${effect}" | xargs)"
    case "${effect}" in
      NoSchedule|PreferNoSchedule|NoExecute) ;;
      *)
        echo "ERROR: invalid toleration effect '${effect}' (use NoSchedule, PreferNoSchedule, NoExecute)."
        exit 1
        ;;
    esac
  done

  if [[ "${HUB_DISABLED}" == "false" && "${HUB_STORAGE_TYPE}" == "file" ]]; then
    local missing=0
    if [[ -z "${HUB_FILE_STORAGE_CLASS}" || "${HUB_FILE_STORAGE_CLASS}" == "CHANGE_ME" ]]; then
      echo "ERROR: HUB_STORAGE_TYPE=file requires HUB_FILE_STORAGE_CLASS (RWX StorageClass name)."
      missing=1
    fi
    if [[ -z "${HUB_FILE_STORAGE_SIZE}" || "${HUB_FILE_STORAGE_SIZE}" == "CHANGE_ME" ]]; then
      echo "ERROR: HUB_STORAGE_TYPE=file requires HUB_FILE_STORAGE_SIZE (e.g. 10Gi)."
      missing=1
    fi
    if [[ "${HUB_FILE_STORAGE_CLASS}" == "thin-csi" ]]; then
      echo "ERROR: thin-csi is RWO; Hub file storage needs ReadWriteMany (RWX)."
      echo "       Set HUB_FILE_STORAGE_CLASS to an RWX class (e.g. ocs-storagecluster-cephfs),"
      echo "       or use HUB_STORAGE_TYPE=S3 instead."
      missing=1
    fi
    if [[ "${missing}" -ne 0 ]]; then
      exit 1
    fi
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

# Apply INFRA_* to Namespace, Subscription, and AnsibleAutomationPlatform CR.
apply_infra_scheduling() {
  python3 - \
    "${OPERATOR_NAMESPACE}" \
    "${OPERATOR_SUBSCRIPTION}" \
    "${INSTANCE_AAP_CR}" \
    "${INFRA_NODE_KEY}" \
    "${INFRA_NODE_VALUE}" \
    "${INFRA_TOLERATION_EFFECTS}" <<'PY'
import json
import pathlib
import sys

import yaml

ns_path = pathlib.Path(sys.argv[1])
sub_path = pathlib.Path(sys.argv[2])
aap_path = pathlib.Path(sys.argv[3])
node_key = sys.argv[4]
node_value = sys.argv[5]
effects = [e.strip() for e in sys.argv[6].split(",") if e.strip()]

node_selector = {node_key: node_value}
tolerations = [
    {"key": node_key, "operator": "Exists", "effect": effect} for effect in effects
]
# Subscription historically lists operator/effect/key; keep that order for readability.
sub_tolerations = [
    {"operator": "Exists", "effect": effect, "key": node_key} for effect in effects
]

# Namespace annotations (OpenShift project defaults)
ns = yaml.safe_load(ns_path.read_text())
ns.setdefault("metadata", {}).setdefault("annotations", {})
ns["metadata"]["annotations"]["openshift.io/node-selector"] = f"{node_key}={node_value}"
ns["metadata"]["annotations"]["scheduler.alpha.kubernetes.io/defaultTolerations"] = json.dumps(
    [{"operator": "Exists", "effect": effect, "key": node_key} for effect in effects],
    separators=(",", ":"),
)

# Subscription config
sub = yaml.safe_load(sub_path.read_text())
sub.setdefault("spec", {}).setdefault("config", {})
sub["spec"]["config"]["nodeSelector"] = node_selector
sub["spec"]["config"]["tolerations"] = sub_tolerations

# AAP CR — platform components use native maps/lists; child components use strings
aap = yaml.safe_load(aap_path.read_text())
spec = aap.setdefault("spec", {})

selector_str = f'{node_key}: "{node_value}"\n'
tolerations_str = "".join(
    f"- key: {node_key}\n  operator: Exists\n  effect: {effect}\n" for effect in effects
)

for platform in ("api", "redis", "database"):
    section = spec.setdefault(platform, {})
    section["node_selector"] = dict(node_selector)
    section["tolerations"] = [dict(t) for t in tolerations]

controller = spec.setdefault("controller", {})
controller["node_selector"] = selector_str
controller["tolerations"] = tolerations_str
controller["postgres_selector"] = selector_str
controller["postgres_tolerations"] = tolerations_str

eda = spec.setdefault("eda", {})
eda["node_selector"] = selector_str
eda["tolerations"] = tolerations_str

hub = spec.setdefault("hub", {})
hub["node_selector"] = selector_str
hub["tolerations"] = tolerations_str

# Drop invalid top-level scheduling if present (operator strips; causes Argo flap)
spec.pop("node_selector", None)
spec.pop("tolerations", None)

def dump(path, data):
    path.write_text(
        yaml.safe_dump(
            data,
            sort_keys=False,
            default_flow_style=False,
            allow_unicode=True,
            width=120,
        )
    )

dump(ns_path, ns)
dump(sub_path, sub)
dump(aap_path, aap)
print(f"    Updated infra key={node_key!r} value={node_value!r} effects={effects}")
PY
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
echo "[Infra scheduling]"
echo "  Namespace:     ${OPERATOR_NAMESPACE}"
echo "  Subscription:  ${OPERATOR_SUBSCRIPTION}"
echo "  AAP CR:        ${INSTANCE_AAP_CR}"
echo "  Node key:      ${INFRA_NODE_KEY}"
echo "  Node value:    '${INFRA_NODE_VALUE}'"
echo "  Effects:       ${INFRA_TOLERATION_EFFECTS}"
echo "------------------------------------------"
backup_file "${OPERATOR_NAMESPACE}"
backup_file "${OPERATOR_SUBSCRIPTION}"
backup_file "${INSTANCE_AAP_CR}"
apply_infra_scheduling
echo "    Done."

echo ""
echo "------------------------------------------"
echo "[Instance / lab]"
echo "  File:              ${INSTANCE_OVERLAY}"
echo "  Hub disabled:         ${HUB_DISABLED}"
echo "  Hub storage_type:     ${HUB_STORAGE_TYPE}"
echo "  Hub file SC:          ${HUB_FILE_STORAGE_CLASS}"
echo "  Hub file size:        ${HUB_FILE_STORAGE_SIZE}"
echo "  Hub S3 Secret:        ${HUB_S3_SECRET}"
echo "  Lightspeed disabled:  ${LIGHTSPEED_DISABLED}"
echo "------------------------------------------"
backup_file "${INSTANCE_OVERLAY}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/disabled" "${HUB_DISABLED}"
echo "    Updated hub.disabled → ${HUB_DISABLED}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/storage_type" "${HUB_STORAGE_TYPE}"
echo "    Updated hub.storage_type → ${HUB_STORAGE_TYPE}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/file_storage_storage_class" "${HUB_FILE_STORAGE_CLASS}"
echo "    Updated hub.file_storage_storage_class → ${HUB_FILE_STORAGE_CLASS}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/file_storage_size" "${HUB_FILE_STORAGE_SIZE}"
echo "    Updated hub.file_storage_size → ${HUB_FILE_STORAGE_SIZE}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/hub/object_storage_s3_secret" "${HUB_S3_SECRET}"
echo "    Updated hub.object_storage_s3_secret → ${HUB_S3_SECRET}"
replace_json6902_value "${INSTANCE_OVERLAY}" "/spec/lightspeed/disabled" "${LIGHTSPEED_DISABLED}"
echo "    Updated lightspeed.disabled → ${LIGHTSPEED_DISABLED}"
echo "    Done."

echo ""
echo "------------------------------------------"
echo "[Hub S3 Secret / lab]"
echo "  name:                  ${HUB_S3_SECRET}"
echo "  s3-access-key-id:      ${S3_ACCESS_KEY_ID}"
echo "  s3-secret-access-key:  ***"
echo "  s3-bucket-name:        ${S3_BUCKET_NAME}"
echo "  s3-region:             ${S3_REGION}"
echo "  s3-endpoint:           ${S3_ENDPOINT}"
echo "------------------------------------------"
for HUB_S3_SECRET_FILE in "${HUB_S3_SECRET_FILES[@]}"; do
  echo "  File: ${HUB_S3_SECRET_FILE}"
  backup_file "${HUB_S3_SECRET_FILE}"
  replace_yaml_key "${HUB_S3_SECRET_FILE}" "name" "${HUB_S3_SECRET}"
  replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-access-key-id" "${S3_ACCESS_KEY_ID}"
  replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-secret-access-key" "${S3_SECRET_ACCESS_KEY}"
  replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-bucket-name" "${S3_BUCKET_NAME}"
  replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-region" "${S3_REGION}"
  replace_yaml_key "${HUB_S3_SECRET_FILE}" "s3-endpoint" "${S3_ENDPOINT}"
  echo "    Updated s3-* keys → ${HUB_S3_SECRET_FILE}"
done
echo "    Done."

echo ""
echo "=========================================="
echo "Update completed (overlays patched only — nothing deployed)."
echo "=========================================="
echo ""
echo "1) Validate Hub S3 (optional, before AAP deploy)"
echo "   Remove any previous validate Job first, then create a fresh one:"
echo "     oc delete job aap-s3-validate -n s4 --ignore-not-found"
echo "     oc apply -k s3-validate/overlays/lab/"
echo "     oc wait -n s4 job/aap-s3-validate --for=condition=complete --timeout=180s"
echo "     oc logs -n s4 job/aap-s3-validate"
echo "   Pass = logs end with: S3 validation PASSED"
echo ""
echo "2) Remove S3 validation resources when finished testing"
echo "     oc delete job aap-s3-validate -n s4 --ignore-not-found"
echo "     oc delete configmap aap-s3-validate-script -n s4 --ignore-not-found"
echo "     oc delete secret aap-hub-s3 -n s4 --ignore-not-found"
echo ""
echo "3) Deploy AAP (after S3 validates, or skip S3 if Hub stays disabled)"
echo "   Manual:"
echo "     oc apply -k operator/overlays/lab/"
echo "     # wait for CSV Succeeded, then:"
echo "     oc apply -k instance/overlays/lab/"
echo "   Argo CD (operator + instance only; does not include s3-validate):"
echo "     oc apply -k argoCD/"
echo "=========================================="
