# Kubernetes-Only Validation Flow

This runbook validates the Crossplane control-plane chain inside Kubernetes only.

It is intentionally designed to prove API model wiring, composition selection, and resource relationships without requiring real Azure resource provisioning.

What this phase validates:

- Developer claims are accepted by public APIs.
- Claims create public XRs.
- Public XRs create internal Azure XRs.
- Internal Azure XRs select the expected composition.

What this phase does not validate:

- Real Azure subscription creation.
- Real Azure virtual network creation.
- End-to-end cloud provisioning success in Azure.

## 1) Apply XRDs

```bash
kubectl apply -f platform/apis/landingzone/xrd.yaml
kubectl apply -f platform/apis/network/xrd.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/xrd.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/xrd.yaml
```

## 2) Apply compositions

```bash
kubectl apply -f platform/functions/function-go-templating.yaml
kubectl apply -f platform/apis/landingzone/composition.yaml
kubectl apply -f platform/apis/network/composition.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/composition.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-corp.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-online.yaml
```

## 3) Apply example LandingZone claims

```bash
kubectl apply -f examples/claims/01-landing-zone-corp.yaml
kubectl apply -f examples/claims/03-landing-zone-online.yaml
```

## 4) Apply example Network claims

```bash
kubectl apply -f examples/claims/02-network-corp.yaml
kubectl apply -f examples/claims/04-network-online.yaml
```

## 5) Inspect claims

```bash
kubectl get landingzones.platform.example.org
kubectl get networks.platform.example.org

kubectl get landingzones.platform.example.org -o yaml
kubectl get networks.platform.example.org -o yaml
```

## 6) Inspect public XRs

```bash
kubectl get xlandingzones.platform.example.org
kubectl get xnetworks.platform.example.org

kubectl get xlandingzones.platform.example.org -o yaml
kubectl get xnetworks.platform.example.org -o yaml
```

## 7) Inspect internal Azure XRs

```bash
kubectl get xazurelandingzones.azure.platform.example.org
kubectl get xazurevirtualnetworks.azure.platform.example.org

kubectl get xazurelandingzones.azure.platform.example.org -o yaml
kubectl get xazurevirtualnetworks.azure.platform.example.org -o yaml
```

## 8) Inspect composition selection

```bash
kubectl get xazurevirtualnetworks.azure.platform.example.org -o custom-columns=NAME:.metadata.name,PROFILE:.spec.networkProfile,SELECTOR:.spec.compositionSelector.matchLabels.platform\.example\.org/network-profile,COMPOSITION:.spec.compositionRef.name

kubectl get composition xazurevirtualnetwork-corp --show-labels
kubectl get composition xazurevirtualnetwork-online --show-labels
```

Expected signals:

- Corp path resolves to profile and selector value `corp` and selects `xazurevirtualnetwork-corp`.
- Online path resolves to profile and selector value `online` and selects `xazurevirtualnetwork-online`.

## 9) Describe resources for troubleshooting

```bash
kubectl describe landingzones.platform.example.org
kubectl describe networks.platform.example.org

kubectl describe xlandingzones.platform.example.org
kubectl describe xnetworks.platform.example.org

kubectl describe xazurelandingzones.azure.platform.example.org
kubectl describe xazurevirtualnetworks.azure.platform.example.org
```

Troubleshooting focus for this phase:

- Kubernetes events on claims and XRs.
- Crossplane conditions and references between claim -> public XR -> internal XR.
- Composition selection and label/selector matching.

Do not treat missing Azure external resources in this phase as a demo failure. This runbook validates Crossplane API modeling and control-plane chaining in Kubernetes, not real cloud provisioning.

## 10) Clean up claims

```bash
kubectl delete -f examples/claims/02-network-corp.yaml
kubectl delete -f examples/claims/04-network-online.yaml
kubectl delete -f examples/claims/01-landing-zone-corp.yaml
kubectl delete -f examples/claims/03-landing-zone-online.yaml
```
