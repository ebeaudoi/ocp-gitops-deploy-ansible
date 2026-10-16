#!/bin/bash
# In-cluster Hub S3 probe (credentials from mounted Secret aap-hub-s3)
set -euo pipefail

export AWS_ACCESS_KEY_ID="$(cat /creds/s3-access-key-id)"
export AWS_SECRET_ACCESS_KEY="$(cat /creds/s3-secret-access-key)"
S3_BUCKET_NAME="$(cat /creds/s3-bucket-name)"
S3_REGION="$(cat /creds/s3-region)"
S3_ENDPOINT="$(cat /creds/s3-endpoint)"

export AWS_DEFAULT_REGION="${S3_REGION}"
export AWS_EC2_METADATA_DISABLED=true
export HOME=/tmp
export AWS_CONFIG_FILE=/tmp/aws-config

cat >"${AWS_CONFIG_FILE}" <<CFG
[default]
region = ${S3_REGION}
s3 =
    addressing_style = path
    signature_version = s3v4
CFG

AWS_SSL_ARGS=()
if [[ "${NO_VERIFY_SSL:-true}" == "true" ]]; then
  AWS_SSL_ARGS=(--no-verify-ssl)
  export PYTHONHTTPSVERIFY=0
  echo "→ TLS certificate verification DISABLED"
fi

aws_s3() {
  aws --endpoint-url "${S3_ENDPOINT}" --region "${S3_REGION}" "${AWS_SSL_ARGS[@]}" "$@"
}

echo "=========================================="
echo "AAP Hub S3 validation (OpenShift Job)"
echo "  endpoint: ${S3_ENDPOINT}"
echo "  region:   ${S3_REGION}"
echo "  bucket:   ${S3_BUCKET_NAME}"
echo "=========================================="

echo "→ Authenticating (s3api list-buckets) ..."
if ! aws_s3 s3api list-buckets >/tmp/s3-ls-out 2>/tmp/s3-ls-err; then
  echo "FAIL: cannot list buckets (bad endpoint or credentials)"
  grep -v 'InsecureRequestWarning\|urllib3/' /tmp/s3-ls-err | sed 's/^/  /' || cat /tmp/s3-ls-err | sed 's/^/  /'
  exit 1
fi
echo "  OK: credentials accepted"

echo "→ Checking bucket '${S3_BUCKET_NAME}' (s3api head-bucket) ..."
set +e
aws_s3 s3api head-bucket --bucket "${S3_BUCKET_NAME}" >/tmp/s3-bkt-out 2>/tmp/s3-bkt-err
rc=$?
set -e
grep -v 'InsecureRequestWarning\|urllib3/' /tmp/s3-bkt-err > /tmp/s3-bkt-err-clean 2>/dev/null || true

if [[ ${rc} -eq 0 ]]; then
  echo "  OK: bucket exists and is accessible"
elif grep -qiE 'NoSuchBucket|Not Found|404' /tmp/s3-bkt-err-clean 2>/dev/null; then
  echo "  MISSING: bucket '${S3_BUCKET_NAME}' does not exist"
  if [[ "${CREATE_BUCKET:-false}" == "true" ]]; then
    echo "→ Creating bucket ..."
    aws_s3 s3api create-bucket --bucket "${S3_BUCKET_NAME}" >/dev/null
    echo "  OK: bucket created"
  else
    echo "  Set CREATE_BUCKET=true on the Job to create it, or create it in S4."
    exit 1
  fi
else
  echo "FAIL: cannot access bucket '${S3_BUCKET_NAME}'"
  sed 's/^/  /' /tmp/s3-bkt-err-clean
  if grep -q "\"Name\": \"${S3_BUCKET_NAME}\"" /tmp/s3-ls-out 2>/dev/null; then
    echo "  NOTE: name appears in list-buckets; treating as OK"
  else
    exit 1
  fi
fi

echo ""
echo "=========================================="
echo "S3 validation PASSED"
echo "=========================================="
