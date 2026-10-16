# Red Hat Ansible Automation Platform (AAP)

Kustomize manifests for the AAP operator and the `AnsibleAutomationPlatform`
instance (controller, EDA, optional Hub and Lightspeed).

## Index

| Section | Description |
|---------|-------------|
| [Prerequisites](#prerequisites) | Cluster and storage requirements |
| [Configure values](#configure-values) | `update-values.sh` (channel, infra, Hub, Lightspeed) |
| [Hub with file (RWX)](#hub-with-file-rwx) | PVC-backed Automation Hub |
| [Hub with S3](#hub-with-s3) | Object-storage-backed Automation Hub |
| [Validate S3](#validate-s3) | Test credentials before deploy |
| [Deploy](#deploy) | Manual apply or Argo CD |
| [Admin password](#admin-password) | Retrieve the platform admin secret |
| [Layout](#layout) | Folder map |
| [Troubleshooting](#troubleshooting) | Argo CD apps, OutOfSync, sync status |

---

## Prerequisites

- OpenShift 4.x, `cluster-admin`, and `oc`
- Infra nodes labeled `node-role.kubernetes.io/infra` (used for placement)
- Default StorageClass such as `thin-csi` (**RWO**) for controller / EDA Postgres
- For Automation Hub, **one** of:
  - an **RWX** StorageClass (file mode), or
  - S3 / S3-compatible object storage (S3 mode)

| Overlay | Catalog | InstallPlan | Channel |
|---------|---------|-------------|---------|
| `*/overlays/lab` | `redhat-operators` | Automatic | `stable-2.7` |

---

## Configure values

Prefer [`update-values.sh`](update-values.sh). It only edits YAML; it does **not** deploy.

```bash
cd ansible
vim update-values.sh    # set the VARIABLES section
./update-values.sh      # patches overlays/base — nothing applied to the cluster
```

### Infra node placement

Applied to the Namespace, Subscription, and AAP CR components:

```bash
INFRA_NODE_KEY="node-role.kubernetes.io/infra"
INFRA_NODE_VALUE=""
INFRA_TOLERATION_EFFECTS="NoSchedule,NoExecute"
```

### Lightspeed

```bash
LIGHTSPEED_DISABLED="true"    # set false to enable Ansible Lightspeed
```

---

## Hub with file (RWX)

Hub file storage needs a **ReadWriteMany** StorageClass. `thin-csi` is RWO and
will not work; the script rejects Hub+file with `thin-csi`.

```bash
oc get storageclass
# Pick an RWX class, e.g. ocs-storagecluster-cephfs or an NFS provisioner
```

In `update-values.sh`:

```bash
HUB_DISABLED="false"
HUB_STORAGE_TYPE="file"
HUB_FILE_STORAGE_CLASS="ocs-storagecluster-cephfs"   # RWX — not thin-csi
HUB_FILE_STORAGE_SIZE="10Gi"
```

Then:

```bash
./update-values.sh
# deploy or sync the instance (see Deploy)
```

This sets on the AAP CR:

| Field | Value |
|-------|--------|
| `spec.hub.disabled` | `false` |
| `spec.hub.storage_type` | `file` |
| `spec.hub.file_storage_storage_class` | your RWX class |
| `spec.hub.file_storage_size` | e.g. `10Gi` |

If you have no RWX class, use [Hub with S3](#hub-with-s3) instead.

---

## Hub with S3

No RWX StorageClass required. Credentials go in `update-values.sh` (do **not**
commit real secrets).

```bash
HUB_DISABLED="false"
HUB_STORAGE_TYPE="S3"
HUB_S3_SECRET="aap-hub-s3"
S3_ACCESS_KEY_ID="..."
S3_SECRET_ACCESS_KEY="..."
S3_BUCKET_NAME="..."
S3_REGION="us-east-1"                    # AWS
# and/or:
S3_ENDPOINT="https://minio.example/"     # S3-compatible (MinIO, S4, …)
```

```bash
./update-values.sh
```

That updates the lab CR overlay (`object_storage_s3_secret`) and both
`hub-s3-secret.yaml` copies (instance + s3-validate). Validate S3 before deploy.

---

## Validate S3

Optional, but recommended when `HUB_STORAGE_TYPE=S3`. Not part of `argoCD/`.

### CLI

Reads variables from `update-values.sh`:

```bash
cd ansible
./validate-s3.sh                              # in-cluster probe
./validate-s3.sh --create-bucket              # create bucket if missing
./validate-s3.sh --local --no-verify-ssl      # route HTTPS + skip TLS verify
```

### OpenShift Job

```bash
# After ./update-values.sh so hub-s3-secret.yaml is current
# Jobs are immutable — delete any previous Job first
oc delete job aap-s3-validate -n s4 --ignore-not-found
oc apply -k s3-validate/overlays/lab/
oc wait -n s4 job/aap-s3-validate --for=condition=complete --timeout=180s
oc logs -n s4 job/aap-s3-validate
```

| Result | What you see |
|--------|----------------|
| Pass | Job `Complete`; logs end with `S3 validation PASSED` |
| Fail | Job `Failed`; logs contain `FAIL:` |

Cleanup:

```bash
oc delete job aap-s3-validate -n s4 --ignore-not-found
oc delete configmap aap-s3-validate-script -n s4 --ignore-not-found
oc delete secret aap-hub-s3 -n s4 --ignore-not-found
```

---

## Deploy

### Manual

```bash
cd ansible

oc apply -k operator/overlays/lab/
# wait until CSV is Succeeded

oc apply -k instance/overlays/lab/
```

Day-2 (CRDs already present) — umbrella:

```bash
oc apply -k overlays/lab/
```

### Argo CD

Deploys AppProject, RBAC, and the operator/instance Applications only
(**not** the S3 validate Job):

```bash
oc apply -k argoCD/
```

Then sync `ansible-operator` and `ansible-instance` (or rely on automated sync).

---

## Admin password

```bash
oc get secret aap-admin-password -n ansible-automation-platform \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## Layout

| Path | Role |
|------|------|
| `operator/` | Namespace, OperatorGroup, Subscription |
| `instance/` | `AnsibleAutomationPlatform` CR (+ Hub S3 secret in lab overlay) |
| `overlays/lab/` | Umbrella (operator + instance); day-2 re-apply |
| `s3-validate/` | One-shot S3 test Job (manual) |
| `argoCD/` | AppProject `appansible`, Applications, AAP controller RBAC |
| `update-values.sh` | Patch lab values without deploying |
| `validate-s3.sh` | CLI S3 probe |

```
ansible/
├── argoCD/
├── overlays/lab/            # umbrella
├── operator/
│   ├── base/
│   └── overlays/lab/
├── instance/
│   ├── base/
│   └── overlays/lab/
├── s3-validate/
├── update-values.sh
└── validate-s3.sh
```

---

## Troubleshooting

### Use the Argo CD API

On OpenShift, `oc get application` may hit `applications.app.k8s.io` (wrong API).
Always use:

```bash
oc get applications.argoproj.io -n openshift-gitops
oc get applications.argoproj.io ansible-operator -n openshift-gitops
oc get applications.argoproj.io ansible-instance -n openshift-gitops
```

### Application not found

```bash
oc get applications.argoproj.io -A
oc apply -k argoCD/          # recreate project + apps if missing
```

### Why is an app OutOfSync?

Argo marks OutOfSync when **live cluster state ≠ desired state from Git**.

**Sync then OutOfSync again on `node_selector` / `tolerations`:** those fields are
**not** valid at top-level `spec` on `AnsibleAutomationPlatform`. The operator
strips them. Scheduling belongs under `spec.controller` / `eda` / `hub` (string
blocks) and `spec.api` / `redis` / `database` (maps/lists). Prefer
`update-values.sh` infra variables, or the Namespace infra annotations.

**1. Which resources differ**

```bash
oc get applications.argoproj.io ansible-instance -n openshift-gitops \
  -o jsonpath='{range .status.resources[*]}{.status}{"\t"}{.kind}/{.name}{"\n"}{end}'
```

**2. Git path / revision Argo is using**

```bash
oc get applications.argoproj.io ansible-instance -n openshift-gitops -o jsonpath='
path={.spec.source.path}
repo={.spec.source.repoURL}
rev={.spec.source.targetRevision}
syncRev={.status.sync.revision}{"\n"}'
```

**3. Diff (Desired vs Live)**

- UI: Applications → `ansible-instance` → App diff
- CLI:

```bash
oc kustomize instance/overlays/lab/

oc get ansibleautomationplatform aap -n ansible-automation-platform -o yaml

oc get ansibleautomationplatform aap -n ansible-automation-platform \
  -o jsonpath='hub.disabled={.spec.hub.disabled} class={.spec.hub.file_storage_storage_class} type={.spec.hub.storage_type}{"\n"}'
```

**4. Hard refresh**

```bash
oc annotate applications.argoproj.io ansible-instance -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

**5. After renaming overlays** (e.g. `connected` → `lab`)

Re-apply Applications so `spec.source.path` matches Git:

```bash
oc apply -k argoCD/
```

Confirm paths are `ansible/operator/overlays/lab` and `ansible/instance/overlays/lab`.

### Sync / health summary

```bash
oc get applications.argoproj.io ansible-instance -n openshift-gitops -o jsonpath='
sync={.status.sync.status}
health={.status.health.status}
op={.status.operationState.phase}
msg={.status.operationState.message}{"\n"}'

oc get applications.argoproj.io ansible-instance -n openshift-gitops \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```
