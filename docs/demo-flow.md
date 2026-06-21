# Walkthrough

This runbook is ordered for a starter-pack walkthrough. It can be used for local learning, team onboarding, or demo sessions.

## Narrative goals

- Developers use simple cloud-agnostic claims.
- Claims bind to public platform composites (`XLandingZone`).
- Platform engineers own Azure implementation details.
- `LandingZone` claim creates `XLandingZone`.
- `XLandingZone` composition creates `XAzureLandingZone`.
- Internal Azure implementation can remain placeholder while the resource chain is structurally valid.

## 1) Apply admin prerequisites (platform engineer)

```bash
kubectl apply -f examples/platform-admin/platform-config.yaml
kubectl apply -f examples/platform-admin/provider-config.yaml
```

## 2) Apply XRDs

```bash
kubectl apply -f platform/apis/landingzone/xrd.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/xrd.yaml
```

## 3) Apply compositions

```bash
kubectl apply -f platform/apis/landingzone/composition.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/composition.yaml
```

## 4) Apply developer claims in order

```bash
kubectl apply -f examples/claims/01-landing-zone-corp.yaml
```

Say:

- The developer API is tiny and cloud-agnostic.
- The claim creates a public composite (`XLandingZone`) that then creates an internal Azure composite (`XAzureLandingZone`).

## 5) Inspect LandingZone claim

```bash
kubectl get landingzones.platform.example.org
kubectl get landingzones.platform.example.org app-dev -o yaml
```

## 6) Inspect XLandingZone

```bash
kubectl get xlandingzones.platform.example.org
kubectl get xlandingzones.platform.example.org app-dev -o yaml
```

## 7) Inspect XAzureLandingZone

```bash
kubectl get xazurelandingzones.azure.platform.example.org
kubectl get xazurelandingzones.azure.platform.example.org app-dev -o yaml
```

Say:

- `LandingZone` is the developer-facing claim.
- `XLandingZone` is the public platform composite contract.
- `XAzureLandingZone` is the internal Azure implementation contract.
- The chain is intentionally valid even while Azure subscription vending remains TODO in the internal composition.

## 8) Clean up claim

```bash
kubectl delete -f examples/claims/01-landing-zone-corp.yaml
```
