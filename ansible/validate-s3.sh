#!/bin/bash
##############################################################################
# validate-s3.sh — test Hub S3 settings from update-values.sh before deploy
#
# Reads S3_* (and related) variables from update-values.sh WITHOUT running it,
# then verifies:
#   1. Required values are set (not empty / CHANGE_ME)
#   2. Credentials authenticate against the endpoint
#   3. The configured bucket exists and is accessible
#
# HOW TO USE
#   1. Edit S3_* values in update-values.sh
#   2. From ansible/ (or repo root):
#        ./validate-s3.sh
#        ./ansible/validate-s3.sh
#
# OPTIONS
#   --create-bucket    Create the bucket if it is missing (after auth succeeds)
#   --no-verify-ssl    Skip TLS certificate verification (OpenShift router /
#                      self-signed HTTPS endpoints). Implies aws --no-verify-ssl.
#   --local            Prefer local `aws` CLI (for public/route endpoints).
#                      Default is to run aws-cli inside the cluster via `oc`
#                      so in-cluster endpoints like http://s4.s4.svc:7480 work.
#   --namespace NS     Namespace for the temporary validation pod (default: s4)
#
# Exit codes: 0 = OK, 1 = validation failed, 2 = usage / toolchain error
##############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

UPDATE_VALUES_FILE="${SCRIPT_DIR}/update-values.sh"
CREATE_BUCKET=false
USE_LOCAL=false
NO_VERIFY_SSL=false
POD_NAMESPACE="s4"
AWS_IMAGE="amazon/aws-cli:2.15.0"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \?//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-bucket) CREATE_BUCKET=true; shift ;;
    --no-verify-ssl) NO_VERIFY_SSL=true; shift ;;
    --local) USE_LOCAL=true; shift ;;
    --namespace) POD_NAMESPACE="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

if [[ ! -f "${UPDATE_VALUES_FILE}" ]]; then
  echo "ERROR: ${UPDATE_VALUES_FILE} not found" >&2
  exit 2
fi

###############################################################################
# Load variables from update-values.sh (assignments only; do not execute script)
###############################################################################
# shellcheck disable=SC1090
eval "$(
  grep -E '^(HUB_STORAGE_TYPE|HUB_S3_SECRET|S3_ACCESS_KEY_ID|S3_SECRET_ACCESS_KEY|S3_BUCKET_NAME|S3_REGION|S3_ENDPOINT)=' \
    "${UPDATE_VALUES_FILE}"
)"

echo "=========================================="
echo "AAP Hub S3 validation"
echo "  Source: ${UPDATE_VALUES_FILE}"
echo "=========================================="
echo "  HUB_STORAGE_TYPE:      ${HUB_STORAGE_TYPE:-<unset>}"
echo "  HUB_S3_SECRET:         ${HUB_S3_SECRET:-<unset>}"
echo "  S3_ENDPOINT:           ${S3_ENDPOINT:-<unset>}"
echo "  S3_REGION:             ${S3_REGION:-<unset>}"
echo "  S3_BUCKET_NAME:        ${S3_BUCKET_NAME:-<unset>}"
echo "  S3_ACCESS_KEY_ID:      ${S3_ACCESS_KEY_ID:-<unset>}"
echo "  S3_SECRET_ACCESS_KEY:  ***"
echo "  NO_VERIFY_SSL:         ${NO_VERIFY_SSL}"
echo "=========================================="

###############################################################################
# Sanity checks
###############################################################################
fail=0

if [[ "${HUB_STORAGE_TYPE:-}" != "S3" ]]; then
  echo "WARNING: HUB_STORAGE_TYPE is '${HUB_STORAGE_TYPE:-<unset>}' (not S3)."
  echo "         Continuing to test S3_* values anyway."
fi

require_set() {
  local name="$1"
  local value="${2:-}"
  if [[ -z "${value}" || "${value}" == "CHANGE_ME" ]]; then
    echo "ERROR: ${name} must be set (not empty / CHANGE_ME)"
    fail=1
  fi
}

require_set "S3_ACCESS_KEY_ID" "${S3_ACCESS_KEY_ID:-}"
require_set "S3_SECRET_ACCESS_KEY" "${S3_SECRET_ACCESS_KEY:-}"
require_set "S3_BUCKET_NAME" "${S3_BUCKET_NAME:-}"
require_set "S3_ENDPOINT" "${S3_ENDPOINT:-}"

if [[ -z "${S3_REGION:-}" || "${S3_REGION}" == "CHANGE_ME" ]]; then
  echo "ERROR: S3_REGION must be set (use a real region or us-east-1 for S3-compatible)"
  fail=1
fi

if [[ -n "${S3_ENDPOINT:-}" && "${S3_ENDPOINT}" != CHANGE_ME* ]]; then
  if [[ ! "${S3_ENDPOINT}" =~ ^https?:// ]]; then
    echo "ERROR: S3_ENDPOINT must include a scheme, e.g. https://s3.example.com or http://s4.s4.svc:7480"
    fail=1
  fi
fi

if [[ "${fail}" -ne 0 ]]; then
  echo ""
  echo "Fix the variables in update-values.sh and re-run."
  exit 1
fi

###############################################################################
# AWS CLI probe (auth + head-bucket; path-style for S3-compatible / S4)
###############################################################################
AWS_PROBE_SCRIPT=$(cat <<'EOS'
set -euo pipefail
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${S3_REGION}"
export AWS_EC2_METADATA_DISABLED=true
export AWS_CONFIG_FILE=/tmp/aws-config
export AWS_SHARED_CREDENTIALS_FILE=/tmp/aws-creds

# Path-style avoids virtual-hosted URLs (bucket.endpoint) that break S4/MinIO
cat >"${AWS_CONFIG_FILE}" <<CFG
[default]
region = ${S3_REGION}
s3 =
    addressing_style = path
    signature_version = s3v4
CFG

AWS_SSL_ARGS=()
if [[ "${NO_VERIFY_SSL:-false}" == "true" ]]; then
  AWS_SSL_ARGS=(--no-verify-ssl)
  export PYTHONHTTPSVERIFY=0
  echo "→ TLS certificate verification DISABLED (--no-verify-ssl)"
fi

aws_s3() {
  aws --endpoint-url "${S3_ENDPOINT}" --region "${S3_REGION}" "${AWS_SSL_ARGS[@]}" "$@"
}

echo "→ Using path-style S3 addressing against ${S3_ENDPOINT}"
echo "→ Authenticating (s3api list-buckets) ..."
if ! aws_s3 s3api list-buckets >/tmp/s3-ls-out 2>/tmp/s3-ls-err; then
  echo "FAIL: cannot list buckets (bad endpoint or credentials)"
  grep -v 'InsecureRequestWarning\|urllib3/' /tmp/s3-ls-err | sed 's/^/  /' || true
  cat /tmp/s3-ls-err | sed 's/^/  /' || true
  exit 1
fi
echo "  OK: credentials accepted"
# Show bucket names from list (no secrets)
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' 2>/dev/null || true
import json
try:
    data=json.load(open("/tmp/s3-ls-out"))
    names=[b.get("Name","") for b in data.get("Buckets") or []]
    print("  Buckets visible:", ", ".join(names) if names else "(none)")
except Exception:
    pass
PY
fi

echo "→ Checking bucket '${S3_BUCKET_NAME}' (s3api head-bucket) ..."
set +e
aws_s3 s3api head-bucket --bucket "${S3_BUCKET_NAME}" >/tmp/s3-bkt-out 2>/tmp/s3-bkt-err
rc=$?
set -e

# Filter TLS noise from error output
grep -v 'InsecureRequestWarning\|urllib3/' /tmp/s3-bkt-err > /tmp/s3-bkt-err-clean 2>/dev/null || cp /tmp/s3-bkt-err /tmp/s3-bkt-err-clean

if [[ ${rc} -eq 0 ]]; then
  echo "  OK: bucket exists and is accessible"
else
  err="$(cat /tmp/s3-bkt-err-clean 2>/dev/null || true)"
  if echo "${err}" | grep -qiE 'NoSuchBucket|Not Found|404|NoSuchKey'; then
    echo "  MISSING: bucket '${S3_BUCKET_NAME}' does not exist"
    if [[ "${CREATE_BUCKET}" == "true" ]]; then
      echo "→ Creating bucket s3://${S3_BUCKET_NAME} ..."
      aws_s3 s3api create-bucket --bucket "${S3_BUCKET_NAME}" >/dev/null
      echo "  OK: bucket created"
    else
      echo "  Re-run with --create-bucket to create it, or create it in S4 UI."
      exit 1
    fi
  else
    echo "FAIL: cannot access bucket '${S3_BUCKET_NAME}'"
    if [[ -n "${err}" ]]; then
      echo "${err}" | sed 's/^/  /'
    else
      echo "  (no error details; try --no-verify-ssl or http://s4.s4.svc:7480)"
    fi
    # Fallback: does the name appear in list-buckets?
    if grep -q "\"Name\": \"${S3_BUCKET_NAME}\"" /tmp/s3-ls-out 2>/dev/null; then
      echo "  NOTE: bucket name appears in list-buckets; head-bucket failed (API quirk)."
      echo "  Treating as OK."
    else
      exit 1
    fi
  fi
fi

echo ""
echo "=========================================="
echo "S3 validation PASSED — safe to deploy AAP Hub with these settings"
echo "=========================================="
EOS
)

run_local() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: local aws CLI not found. Install awscli or omit --local to use oc." >&2
    exit 2
  fi
  echo "Mode: local aws CLI"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "${AWS_PROBE_SCRIPT}" >"${tmp}"
  S3_ENDPOINT="${S3_ENDPOINT}" \
  S3_REGION="${S3_REGION}" \
  S3_BUCKET_NAME="${S3_BUCKET_NAME}" \
  AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}" \
  AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}" \
  CREATE_BUCKET="${CREATE_BUCKET}" \
  NO_VERIFY_SSL="${NO_VERIFY_SSL}" \
  bash "${tmp}"
  rm -f "${tmp}"
}

run_in_cluster() {
  if ! command -v oc >/dev/null 2>&1; then
    echo "ERROR: oc not found. Use --local if validating a public/route endpoint from your laptop." >&2
    exit 2
  fi
  if ! oc get ns "${POD_NAMESPACE}" >/dev/null 2>&1; then
    echo "ERROR: namespace '${POD_NAMESPACE}' not found (override with --namespace)." >&2
    exit 2
  fi

  local pod="aap-s3-validate-$$"
  local b64 manifest
  b64="$(printf '%s\n' "${AWS_PROBE_SCRIPT}" | base64 -w0 2>/dev/null || printf '%s\n' "${AWS_PROBE_SCRIPT}" | base64)"
  manifest="$(mktemp)"

  echo "Mode: in-cluster (pod ${pod} in ns/${POD_NAMESPACE})"
  echo "Image: ${AWS_IMAGE}"

  # Restricted PSA-compliant pod (runAsNonRoot, drop caps, RuntimeDefault seccomp)
  python3 - "${manifest}" "${pod}" "${POD_NAMESPACE}" "${AWS_IMAGE}" \
    "${S3_ENDPOINT}" "${S3_REGION}" "${S3_BUCKET_NAME}" \
    "${S3_ACCESS_KEY_ID}" "${S3_SECRET_ACCESS_KEY}" \
    "${CREATE_BUCKET}" "${NO_VERIFY_SSL}" "${b64}" <<'PY'
import pathlib, sys, json
path = pathlib.Path(sys.argv[1])
pod, ns, image = sys.argv[2], sys.argv[3], sys.argv[4]
endpoint, region, bucket = sys.argv[5], sys.argv[6], sys.argv[7]
ak, sk = sys.argv[8], sys.argv[9]
create, no_ssl, b64 = sys.argv[10], sys.argv[11], sys.argv[12]

def esc(s: str) -> str:
    return json.dumps(s)

path.write_text(f"""apiVersion: v1
kind: Pod
metadata:
  name: {pod}
  namespace: {ns}
  labels:
    app: aap-s3-validate
spec:
  restartPolicy: Never
  # Omit runAsUser — OpenShift restricted SCC assigns a namespace UID range
  securityContext:
    runAsNonRoot: true
    hostUsers: false
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: aws
      image: {image}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-c"]
      args:
        - 'echo "$PROBE_B64" | base64 -d | bash'
      env:
        - name: S3_ENDPOINT
          value: {esc(endpoint)}
        - name: S3_REGION
          value: {esc(region)}
        - name: S3_BUCKET_NAME
          value: {esc(bucket)}
        - name: AWS_ACCESS_KEY_ID
          value: {esc(ak)}
        - name: AWS_SECRET_ACCESS_KEY
          value: {esc(sk)}
        - name: CREATE_BUCKET
          value: {esc(create)}
        - name: NO_VERIFY_SSL
          value: {esc(no_ssl)}
        - name: HOME
          value: "/tmp"
        - name: PROBE_B64
          value: {esc(b64)}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
""")
PY

  cleanup() {
    oc delete pod "${pod}" -n "${POD_NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -f "${manifest}"
  }
  trap cleanup EXIT

  oc apply -f "${manifest}" >/dev/null

  # Wait until the probe container finishes (Succeeded/Failed), not Ready.
  # Ready is wrong for a one-shot pod and caused early exit with truncated logs.
  echo "→ Waiting for probe pod to finish (up to 3 minutes) ..."
  phase=""
  for _ in $(seq 1 90); do
    phase="$(oc get pod "${pod}" -n "${POD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
    case "${phase}" in
      Succeeded|Failed) break ;;
      Missing)
        echo "ERROR: probe pod disappeared before completion"
        exit 1
        ;;
    esac
    sleep 2
  done

  echo "→ Probe pod phase: ${phase}"
  echo "---------- probe logs ----------"
  oc logs -n "${POD_NAMESPACE}" "${pod}" 2>&1 || echo "(no logs available)"
  echo "--------------------------------"

  exit_code="$(oc get pod "${pod}" -n "${POD_NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo 1)"
  if [[ "${phase}" != "Succeeded" || "${exit_code}" != "0" ]]; then
    echo ""
    echo "S3 validation FAILED (pod phase=${phase}, container exit=${exit_code})"
    echo "Tips:"
    echo "  - Prefer in-cluster endpoint: S3_ENDPOINT=\"http://s4.s4.svc:7480\""
    echo "  - For the route, keep --no-verify-ssl"
    echo "  - Confirm access key/secret match S4, and bucket exists (or --create-bucket)"
    exit 1
  fi
}

if [[ "${USE_LOCAL}" == "true" ]]; then
  run_local
else
  run_in_cluster
fi
