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

Edit channel / catalog / hub `file_storage_storage_class` in the overlays to match your environment.

## What each folder does

| Path | Role |
|------|------|
| `operator/` | Namespace, OperatorGroup, Subscription |
| `instance/` | `AnsibleAutomationPlatform` CR (controller + EDA + hub) |
| `overlays/{connected,airgapped}/` | Umbrella (day-2 re-apply only; first install apply operator then instance) |

## Prerequisites

- OpenShift 4.x, cluster-admin, `oc`
- Infra nodes (`node-role.kubernetes.io/infra`) for Subscription / namespace / CR placement
- A ReadWriteMany StorageClass for Automation Hub (default overlay value: `ocs-storagecluster-cephfs`)

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

## Retrieve admin password

```bash
oc get secret aap-admin-password -n ansible-automation-platform \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Layout

```
ansible/
├── overlays/{connected,airgapped}/     # umbrella (operator + instance)
├── operator/
│   ├── base/
│   └── overlays/{connected,airgapped}/

└── instance/
    ├── base/
    └── overlays/{connected,airgapped}/
```
