# ocp-gitops-deploy-ansible

GitOps Kustomize manifests to deploy **Red Hat Ansible Automation Platform (AAP)** on OpenShift.

## Index

| Section | Description |
|---------|-------------|
| [Repository layout](#repository-layout) | What each path contains |
| [Quick start](#quick-start) | Manual or Argo CD apply |
| [Full guide](ansible/README.md) | Configure values, Hub storage, S3 validation, troubleshooting |

### Repository layout

| Path | Description |
|------|-------------|
| [`ansible/`](ansible/) | AAP operator + `AnsibleAutomationPlatform` instance |
| [`ansible/README.md`](ansible/README.md) | Full deploy guide (configuration, Hub file/S3, Argo, troubleshooting) |
| [`ansible/update-values.sh`](ansible/update-values.sh) | Patch channel, catalog, infra, Hub (file/S3), Lightspeed, S3 secret |
| [`ansible/validate-s3.sh`](ansible/validate-s3.sh) | CLI probe for Hub S3 endpoint / credentials / bucket |
| [`ansible/s3-validate/`](ansible/s3-validate/) | OpenShift Job to test Hub S3 (manual apply; **not** in `argoCD/`) |
| [`ansible/argoCD/`](ansible/argoCD/) | AppProject, operator/instance Applications, and AAP RBAC |

## Quick start

**1. Configure** (optional but recommended):

```bash
cd ansible
vim update-values.sh    # channel, Hub file/S3, infra, Lightspeed, …
./update-values.sh      # patches YAML only — does not deploy
```

**2. Deploy** — pick one:

Manual:

```bash
oc apply -k ansible/operator/overlays/lab/
# wait for CSV Succeeded

oc apply -k ansible/instance/overlays/lab/
```

Argo CD (operator + instance only; does not deploy S3 validation):

```bash
oc apply -k ansible/argoCD/
```

For Hub storage (file vs S3), S3 validation, passwords, and OutOfSync help, see
[`ansible/README.md`](ansible/README.md).
