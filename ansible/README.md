# Red Hat Ansible Automation Platform (AAP)

Kustomize manifests for the AAP operator and `AnsibleAutomationPlatform` instance.

## Purpose

Install AAP on an OpenShift cluster: operator → unified platform instance
(controller, EDA, hub; lightspeed disabled).

## Overlays

| Overlay | Catalog | InstallPlan | Channel |
|---------|---------|-------------|---------|
| `*/overlays/connected` | `redhat-operators` | Automatic | `stable-2.7` |
| `*/overlays/airgapped` | `ebdn-redhat-operators` | Manual | `stable-2.7` |

Edit values with [`update-values.sh`](update-values.sh) (preferred), or edit the overlay files directly.

```bash
cd ansible
vim update-values.sh    # set channel / catalog / Hub options
./update-values.sh       # patches overlays only — does not deploy
```

Hub is **disabled** in overlays: `thin-csi` is RWO, and Hub file storage needs RWX. Re-enable Hub when you have an RWX StorageClass or configure `storage_type: S3` / Azure.

## What each folder does

| Path | Role |
|------|------|
| `operator/` | Namespace, OperatorGroup, Subscription |
| `instance/` | `AnsibleAutomationPlatform` CR (controller + EDA + hub) |
| `overlays/{connected,airgapped}/` | Umbrella (day-2 re-apply only; first install apply operator then instance) |
| `argoCD/` | AppProject `appansible`, Applications, and AAP RBAC for the GitOps controller |

## Prerequisites

- OpenShift 4.x, cluster-admin, `oc`
- Infra nodes (`node-role.kubernetes.io/infra`) for Subscription / namespace / CR placement
- Default StorageClass `thin-csi` (RWO) for controller/EDA Postgres PVCs
- RWX StorageClass or object storage if you enable Automation Hub

## Manual apply

```bash
export OVERLAY=connected   # or airgapped
cd ansible

oc apply -k operator/overlays/${OVERLAY}/
# airgapped: approve the InstallPlan, then wait for CSV Succeeded

oc apply -k instance/overlays/${OVERLAY}/
```

Day-2 full stack (CRDs already present):

```bash
oc apply -k overlays/${OVERLAY}/
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
├── argoCD/                             # AppProject + Applications + AAP RBAC
├── overlays/{connected,airgapped}/     # umbrella (operator + instance)
├── operator/
│   ├── base/
│   └── overlays/{connected,airgapped}/
└── instance/
    ├── base/
    └── overlays/{connected,airgapped}/
```
