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
kubectl apply -f platform/apis/network/xrd.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/xrd.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/xrd.yaml
```

## 3) Apply compositions

```bash
kubectl apply -f platform/apis/landingzone/composition.yaml
kubectl apply -f platform/apis/network/composition.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/composition.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-corp.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-online.yaml
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

## 8) Apply corp network claim and inspect selection

```bash
kubectl apply -f examples/claims/02-network-corp.yaml
kubectl get xnetworks.platform.example.org -o yaml
kubectl get xazurevirtualnetworks.azure.platform.example.org -o yaml
kubectl get composition xazurevirtualnetwork-corp -o yaml
```

Check:

- `XNetwork.status.networkProfile` is `corp`.
- `XAzureVirtualNetwork.spec.networkProfile` is `corp`.
- `XAzureVirtualNetwork.spec.compositionSelector.matchLabels.platform.example.org/network-profile` is `corp`.
- Internal composition `xazurevirtualnetwork-corp` has label `platform.example.org/network-profile: corp`.

## 9) Apply online landing zone + network and inspect selection

```bash
kubectl apply -f examples/claims/03-landing-zone-online.yaml
kubectl apply -f examples/claims/04-network-online.yaml
kubectl get xnetworks.platform.example.org -o yaml
kubectl get xazurevirtualnetworks.azure.platform.example.org -o yaml
kubectl get composition xazurevirtualnetwork-online -o yaml
```

Check:

- `XNetwork.status.networkProfile` is `online`.
- `XAzureVirtualNetwork.spec.networkProfile` is `online`.
- `XAzureVirtualNetwork.spec.compositionSelector.matchLabels.platform.example.org/network-profile` is `online`.
- Internal composition `xazurevirtualnetwork-online` has label `platform.example.org/network-profile: online`.

## 10) Clean up claims

```bash
kubectl delete -f examples/claims/01-landing-zone-corp.yaml
kubectl delete -f examples/claims/02-network-corp.yaml
kubectl delete -f examples/claims/03-landing-zone-online.yaml
kubectl delete -f examples/claims/04-network-online.yaml
```
