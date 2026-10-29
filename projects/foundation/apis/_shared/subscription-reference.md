# Shared `spec.subscription` schema (copy into every building block)

Copy these snippets unchanged into the XRD of StorageAccount, KeyVault, ContainerApp and VirtualNetwork. LandingZone uses the same field with its own meaning (the name of the Subscription it creates; omitted = its own name). Changing the text is a recorded decision.

## `spec` (properties and CEL)

```yaml
x-kubernetes-validations:
  - rule: "!has(oldSelf.subscription) || (has(self.subscription) && self.subscription == oldSelf.subscription)"
    message: "spec.subscription can't be changed once set. Create a new <Kind> instead."
properties:
  subscription:
    type: string
    description: >-
      Name of a Subscription in this namespace that the resources are created in. Optional.
      If omitted, the platform uses the namespace's only Ready Subscription. If the namespace
      has none or more than one, no resources are created and the SubscriptionResolved condition
      explains why. Set this field to choose explicitly. The resolved name is recorded in
      status.subscription and never changes afterwards. It can't be changed once set; to move,
      create a new resource.
    maxLength: 63
    pattern: "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
```

## `status` (write-once pin and environment)

```yaml
x-kubernetes-validations:
  - rule: "!has(oldSelf.subscription) || (has(self.subscription) && self.subscription == oldSelf.subscription)"
    message: "status.subscription is write-once."
  - rule: "!has(oldSelf.subscriptionUid) || (has(self.subscriptionUid) && self.subscriptionUid == oldSelf.subscriptionUid)"
    message: "status.subscriptionUid is write-once."
  - rule: "!has(oldSelf.subscriptionId) || (has(self.subscriptionId) && self.subscriptionId == oldSelf.subscriptionId)"
    message: "status.subscriptionId is write-once."
  - rule: "!has(oldSelf.environment) || (has(self.environment) && self.environment == oldSelf.environment)"
    message: "status.environment is write-once."
properties:
  subscription: {type: string}      # name of the Subscription XR
  subscriptionUid: {type: string}   # its Kubernetes UID
  subscriptionId: {type: string}    # its Azure subscription ID
  environment:
    type: object
    properties:
      location: {type: string}
      resourceGroupName: {type: string}
```

Rules for all building blocks:

- The `spec.parameters.location` and `resourceGroupName` overrides are immutable once set (spec-level CEL, same shape as the subscription rule) and have no defaults in the schema; the environment supplies the default.
- Conditions `Ready`, `Synced`, `SubscriptionResolved`, `EnvironmentValid`, `EnvironmentDrift` are not declared in the schema.
- Printer columns: `SUBSCRIPTION` (`.status.subscription`), `LOCATION` (`.status.environment.location`) where a location applies, `READY`, `SYNCED`, `AGE`.
- Every status key a function-kro step emits must also be declared in the XRD.
