# Red Hat Ansible Automation Platform (AAP)

Kustomize manifests for the AAP operator and `AnsibleAutomationPlatform` instance.

## Purpose

Install AAP on an OpenShift cluster: operator → unified platform instance
(controller + EDA; Hub via file/RWX or S3 — see below).

## Overlay

| Overlay | Catalog | InstallPlan | Channel |
|---------|---------|-------------|---------|
| `*/overlays/lab` | `redhat-operators` | Automatic | `stable-2.7` |

Edit values with [`update-values.sh`](update-values.sh) (preferred), or edit the overlay files directly.

```bash
cd ansible
vim update-values.sh    # set channel / catalog / Hub / infra / Lightspeed options
./update-values.sh       # patches overlays/base YAML only — does not deploy
```

**Infra node placement** (Namespace + Subscription + AAP CR):

```bash
INFRA_NODE_KEY="node-role.kubernetes.io/infra"
INFRA_NODE_VALUE=""
INFRA_TOLERATION_EFFECTS="NoSchedule,NoExecute"
```

### Automation Hub storage

Hub needs either **file** (RWX PVC) or **S3** object storage. The default lab
StorageClass `thin-csi` is **RWO** and cannot back Hub file storage.

List StorageClasses and pick one with `RWX` (or use S3):

```bash
oc get storageclass
# Look for something like ocs-storagecluster-cephfs, nfs-*, or another RWX class
```

#### Hub with file (RWX)

```bash
# in update-values.sh:
HUB_DISABLED="false"
HUB_STORAGE_TYPE="file"
HUB_FILE_STORAGE_CLASS="ocs-storagecluster-cephfs"   # must be RWX — not thin-csi
HUB_FILE_STORAGE_SIZE="10Gi"
```

Then:

```bash
./update-values.sh
# deploy / sync instance as usual
```

That sets on the AAP CR:

- `spec.hub.disabled: false`
- `spec.hub.storage_type: file`
- `spec.hub.file_storage_storage_class`
- `spec.hub.file_storage_size`

The script **refuses** Hub+file with `thin-csi` (RWO). If you have no RWX class,
use S3 instead (below).

#### Hub with S3

```bash
# in update-values.sh:
HUB_DISABLED="false"
HUB_STORAGE_TYPE="S3"
HUB_S3_SECRET="aap-hub-s3"
S3_ACCESS_KEY_ID="..."
S3_SECRET_ACCESS_KEY="..."
S3_BUCKET_NAME="..."
S3_REGION="us-east-1"          # AWS
# and/or:
S3_ENDPOINT="https://minio.example/"   # S3-compatible
```

Then run `./update-values.sh`. That patches the lab CR overlay (Hub + Lightspeed),
`hub-s3-secret.yaml` (all `s3-*` keys), and `object_storage_s3_secret`.
Do not commit real credentials. Validate S3 before deploy (next section).

Lightspeed (either storage mode):

```bash
LIGHTSPEED_DISABLED="true"     # false to enable Ansible Lightspeed
```

**Validate S3 before deploy**

CLI (reads `update-values.sh`):

```bash
cd ansible
./validate-s3.sh                              # in-cluster probe
./validate-s3.sh --create-bucket              # create bucket if missing
./validate-s3.sh --local --no-verify-ssl      # route HTTPS + skip TLS verify
```

OpenShift Job (uses `hub-s3-secret.yaml` values; not part of `argoCD/`):

```bash
# After ./update-values.sh so hub-s3-secret.yaml is current:
# Always delete a previous Job before re-running (Jobs are immutable).
oc delete job aap-s3-validate -n s4 --ignore-not-found
oc apply -k s3-validate/overlays/lab/
oc wait -n s4 job/aap-s3-validate --for=condition=complete --timeout=180s
oc logs -n s4 job/aap-s3-validate
```

- **Pass:** Job `Complete` and logs contain `S3 validation PASSED`
- **Fail:** Job `Failed` / logs contain `FAIL:`

Remove S3 validation when done:

```bash
oc delete job aap-s3-validate -n s4 --ignore-not-found
oc delete configmap aap-s3-validate-script -n s4 --ignore-not-found
oc delete secret aap-hub-s3 -n s4 --ignore-not-found
```

## What each folder does

| Path | Role |
|------|------|
| `operator/` | Namespace, OperatorGroup, Subscription |
| `instance/` | `AnsibleAutomationPlatform` CR (controller + EDA; Hub disabled in lab) |
| `overlays/lab/` | Umbrella (day-2 re-apply only; first install apply operator then instance) |
| `argoCD/` | AppProject `appansible`, Applications, and AAP RBAC for the GitOps controller |

## Prerequisites

- OpenShift 4.x, cluster-admin, `oc`
- Infra nodes (`node-role.kubernetes.io/infra`) for Subscription / namespace / CR placement
- Default StorageClass `thin-csi` (RWO) for controller/EDA Postgres PVCs
- Hub **file** mode: an RWX StorageClass (`HUB_FILE_STORAGE_CLASS`); or Hub **S3** mode (credentials in `update-values.sh`)

## Manual apply

```bash
cd ansible

oc apply -k operator/overlays/lab/
# wait for CSV Succeeded

oc apply -k instance/overlays/lab/
```

Day-2 full stack (CRDs already present):

```bash
oc apply -k overlays/lab/
```

Via Argo CD (project + apps + controller RBAC):

```bash
oc apply -k argoCD/
```

## Retrieve admin password

```bash
oc get secret aap-admin-password -n ansible-automation-platform \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Layout

```
ansible/
├── argoCD/                  # AppProject + Applications + AAP RBAC
├── overlays/lab/            # umbrella (operator + instance)
├── operator/
│   ├── base/
│   └── overlays/lab/
└── instance/
    ├── base/
    └── overlays/lab/
```

## Troubleshooting

### Use the Argo CD API (not `oc get application`)

On OpenShift, `oc get application` may resolve to `applications.app.k8s.io` (wrong API)
and return NotFound. Always use the Argo CD plural:

```bash
oc project openshift-gitops   # optional; avoids confusion with other projects

oc get applications.argoproj.io -n openshift-gitops
oc get applications.argoproj.io ansible-operator -n openshift-gitops
oc get applications.argoproj.io ansible-instance -n openshift-gitops
```

### Application not found

```bash
# List all Argo CD apps on the cluster
oc get applications.argoproj.io -A

# Re-create project + apps if missing
oc apply -k argoCD/
```

### Why is an app OutOfSync?

Argo marks OutOfSync when **live cluster state ≠ desired state from Git**.

**Sync then immediately OutOfSync on `node_selector` / `tolerations`:** those fields are **not** valid at top-level `spec` on `AnsibleAutomationPlatform`. The operator strips them after reconcile. Put scheduling under `spec.controller` / `eda` / `hub` (string block scalars) and `spec.api` / `redis` / `database` (native maps/lists). The namespace already has `openshift.io/node-selector` and default tolerations for infra.

**1. See which resources differ**

```bash
oc get applications.argoproj.io ansible-instance -n openshift-gitops \
  -o jsonpath='{range .status.resources[*]}{.status}{"\t"}{.kind}/{.name}{"\n"}{end}'
```

**2. See what Git path / revision Argo is using**

```bash
oc get applications.argoproj.io ansible-instance -n openshift-gitops -o jsonpath='
path={.spec.source.path}
repo={.spec.source.repoURL}
rev={.spec.source.targetRevision}
syncRev={.status.sync.revision}{"\n"}'
```

**3. See the actual diff (best view of “why”)**

- **Argo CD UI:** Applications → `ansible-instance` → **App diff** (or DIFF tab).
  That shows Desired (Git) vs Live (cluster) field by field.

- **CLI — compare Git desired vs live CR:**

```bash
# Desired from the lab overlay (local checkout; should match Git after push)
oc kustomize instance/overlays/lab/

# Live on the cluster
oc get ansibleautomationplatform aap -n ansible-automation-platform -o yaml

# Focused Hub fields (common drift)
oc get ansibleautomationplatform aap -n ansible-automation-platform \
  -o jsonpath='hub.disabled={.spec.hub.disabled} class={.spec.hub.file_storage_storage_class} type={.spec.hub.storage_type}{"\n"}'
```

**4. Hard refresh Argo’s view of Git**

```bash
oc annotate applications.argoproj.io ansible-instance -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

**5. After renaming overlays (e.g. connected → lab)**

Update the Application manifests and re-apply so `spec.source.path` matches Git:

```bash
oc apply -k argoCD/
```

Confirm path is `ansible/instance/overlays/lab` (and operator likewise).

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
