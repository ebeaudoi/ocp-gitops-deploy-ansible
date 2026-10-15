# Red Hat Ansible Automation Platform (AAP)

Kustomize manifests for the AAP operator and `AnsibleAutomationPlatform` instance.

## Purpose

Install AAP on an OpenShift cluster: operator → unified platform instance
(controller + EDA; Hub disabled in lab; lightspeed disabled).

## Overlay

| Overlay | Catalog | InstallPlan | Channel |
|---------|---------|-------------|---------|
| `*/overlays/lab` | `redhat-operators` | Automatic | `stable-2.7` |

Edit values with [`update-values.sh`](update-values.sh) (preferred), or edit the overlay files directly.

```bash
cd ansible
vim update-values.sh    # set channel / catalog / Hub options
./update-values.sh       # patches overlays only — does not deploy
```

Hub is **disabled** in the lab overlay: `thin-csi` is RWO, and Hub file storage needs RWX. Re-enable Hub when you have an RWX StorageClass or configure `storage_type: S3` / Azure.

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
- RWX StorageClass or object storage if you enable Automation Hub

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
