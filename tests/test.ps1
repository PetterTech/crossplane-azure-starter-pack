#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Get-Command crossplane, docker -ErrorAction Stop | Out-Null
& docker info --format '{{.ServerVersion}}'
if ($LASTEXITCODE -ne 0) {
    throw 'Docker must be running to render compositions.'
}

$root = Split-Path $PSScriptRoot -Parent
$foundation = Join-Path $root 'projects\foundation'
$services = Join-Path $root 'projects\services'
$stacks = Join-Path $root 'projects\stacks'
$functions = Join-Path $root 'crossplane\functions.yaml'
$providers = Join-Path $root 'crossplane\providers.yaml'
$crossplaneVersion = 'v2.4.3'

function Assert-RenderedKind {
    param(
        [string]$Rendered,
        [string]$Kind,
        [bool]$Expected
    )

    $found = [regex]::IsMatch($Rendered, "(?m)^kind:\s+$([regex]::Escape($Kind))\s*$")
    if ($found -ne $Expected) {
        $expectation = if ($Expected) { 'present' } else { 'absent' }
        throw "Expected $Kind to be $expectation in rendered output."
    }
}

function Assert-RenderedTags {
    param(
        [string]$Rendered,
        [string[]]$Kinds,
        [System.Collections.IDictionary]$Expected
    )

    $documents = [regex]::Split($Rendered, '(?m)^---\s*$')
    foreach ($kind in $Kinds) {
        $resources = @($documents | Where-Object {
                $_ -match "(?m)^kind:\s+$([regex]::Escape($kind))\s*$"
            })
        if ($resources.Count -ne 1) {
            throw "Expected one rendered $kind, found $($resources.Count)."
        }

        foreach ($key in $Expected.Keys) {
            $pattern = "(?m)^      $([regex]::Escape([string]$key)):\s+$([regex]::Escape([string]$Expected[$key]))\s*$"
            if ($resources[0] -notmatch $pattern) {
                throw "Rendered $kind is missing expected tag '${key}: $($Expected[$key])'."
            }
        }
    }
}

function Get-RenderedResource {
    param([string]$Rendered, [string]$Kind)

    $resources = @([regex]::Split($Rendered, '(?m)^---\s*$') | Where-Object {
            $_ -match "(?m)^kind:\s+$([regex]::Escape($Kind))\s*$"
        })
    if ($resources.Count -ne 1) {
        throw "Expected one rendered $Kind, found $($resources.Count)."
    }
    return $resources[0]
}

function Assert-RenderedSetting {
    param([string]$Resource, [string]$Setting)

    if ($Resource -notmatch "(?m)^ +(?:- )?$([regex]::Escape($Setting))\s*$") {
        throw "Rendered resource is missing '$Setting'."
    }
}

$cases = @(
    @{ Name = 'space-private'; Api = 'space'; XR = 'examples\space-private.yaml' }
    @{ Name = 'space-public'; Api = 'space'; XR = 'examples\space-public.yaml' }
    @{
        Name = 'space-ready'
        Api = 'space'
        XR = 'tests\space\xr-ready.yaml'
        Observed = 'tests\space\observed-ready.yaml'
    }
    @{
        Name = 'network-private'
        Api = 'network'
        XR = 'examples\network-private.yaml'
        Observed = 'tests\network\observed-ready.yaml'
        PrivateConnections = $true
        ResourceGroup = 'network-private-network'
        ExpectedTags = @{
            owner = 'platform'
            'managed-by' = 'crossplane'
            environment = 'development'
        }
    }
    @{
        Name = 'network-public'
        Api = 'network'
        XR = 'examples\network-public.yaml'
        Observed = 'tests\network\observed-public.yaml'
        PrivateConnections = $false
        ResourceGroup = 'network-public-network'
    }
    @{ Name = 'bucket'; Project = $services; Api = 'bucket'; XR = 'examples\bucket.yaml' }
    @{
        Name = 'bucket-ready'
        Project = $services
        Api = 'bucket'
        XR = 'examples\bucket.yaml'
        Observed = 'tests\bucket\observed-ready.yaml'
        Replication = 'ZRS'
        Containers = 2
        ExpectedTags = @{
            owner = 'platform'
            'managed-by' = 'crossplane'
            environment = 'development'
        }
    }
    @{
        Name = 'bucket-geo'
        Project = $services
        Api = 'bucket'
        XR = 'tests\bucket\xr-geo.yaml'
        Observed = 'tests\bucket\observed-ready.yaml'
        Replication = 'GZRS'
        Containers = 1
    }
    @{ Name = 'secretstore'; Project = $services; Api = 'secretstore'; XR = 'examples\secretstore.yaml' }
    @{
        Name = 'secretstore-ready'
        Project = $services
        Api = 'secretstore'
        XR = 'examples\secretstore.yaml'
        Observed = 'tests\secretstore\observed-ready.yaml'
        ExpectedTags = @{
            owner = 'platform'
            'managed-by' = 'crossplane'
            environment = 'development'
        }
    }
    @{ Name = 'app'; Project = $services; Api = 'app'; XR = 'examples\app.yaml'; AppKinds = @() }
    @{
        Name = 'app-network-ready'; Project = $services; Api = 'app'; XR = 'examples\app.yaml'
        Observed = 'tests\app\observed-ready.yaml'; ObservedKinds = @('Usage')
        AppKinds = @('ResourceGroup')
    }
    @{
        Name = 'app-group-ready'; Project = $services; Api = 'app'; XR = 'examples\app.yaml'
        Observed = 'tests\app\observed-ready.yaml'; ObservedKinds = @('Usage', 'ResourceGroup')
        AppKinds = @('ResourceGroup', 'Environment')
    }
    @{
        Name = 'app-environment-ready'; Project = $services; Api = 'app'; XR = 'examples\app.yaml'
        Observed = 'tests\app\observed-ready.yaml'; ObservedKinds = @('Usage', 'ResourceGroup', 'Environment')
        AppKinds = @('ResourceGroup', 'Environment', 'ContainerApp', 'PrivateEndpoint')
    }
    @{
        Name = 'app-ready'; Project = $services; Api = 'app'; XR = 'examples\app.yaml'
        Observed = 'tests\app\observed-ready.yaml'
        AppKinds = @('ResourceGroup', 'Environment', 'ContainerApp', 'PrivateEndpoint')
        ExpectedTags = @{ owner = 'platform'; 'managed-by' = 'crossplane'; environment = 'development' }
    }
    @{ Name = 'app-public'; Project = $services; Api = 'app'; XR = 'examples\app-public.yaml'; AppKinds = @() }
    @{
        Name = 'app-public-ready'; Project = $services; Api = 'app'; XR = 'examples\app-public.yaml'
        Observed = 'tests\app\observed-ready.yaml'; ObservedKinds = @('Usage', 'ResourceGroup', 'Environment', 'ContainerApp')
        Public = $true
        AppKinds = @('ResourceGroup', 'Environment', 'ContainerApp')
        ExpectedTags = @{ owner = 'platform'; 'managed-by' = 'crossplane'; environment = 'development' }
    }
    @{
        Name = 'app-public-updated'; Project = $services; Api = 'app'; XR = 'examples\app-public.yaml'
        Observed = 'tests\app\observed-ready.yaml'; ObservedKinds = @('Usage', 'ResourceGroup', 'Environment', 'ContainerApp')
        Public = $true; Image = 'ghcr.io/pettertech/demo-app:1.0.3'; Port = 9090
        AppKinds = @('ResourceGroup', 'Environment', 'ContainerApp')
    }
    @{
        Name = 'app-resolved-provider'; Project = $services; Api = 'app'; XR = 'examples\app.yaml'
        Observed = 'tests\app\observed-ready.yaml'; ProviderName = 'space-credentials'
        AppKinds = @('ResourceGroup', 'Environment', 'ContainerApp', 'PrivateEndpoint')
    }
)

$waiting = 'waiting for Network private-network and Space development to publish status'
$dependencies = @(
    @{ Api = 'bucket'; Name = 'missing-network'; Kind = 'Network'; Remove = $true; Error = 'Network private-network not found' }
    @{ Api = 'bucket'; Name = 'missing-space'; Kind = 'Space'; Remove = $true; Error = 'Space development not found' }
    @{ Api = 'bucket'; Name = 'missing-space-before-storage'; Kind = 'Space'; Remove = $true; UsageOnly = $true; Error = 'Space development not found' }
    @{ Api = 'bucket'; Name = 'network-not-ready'; Kind = 'Network'; NotReady = $true }
    @{ Api = 'bucket'; Name = 'space-not-ready'; Kind = 'Space'; NotReady = $true }
    @{ Api = 'bucket'; Name = 'missing-account-id'; Kind = 'Account'; Field = 'id' }
    @{ Api = 'bucket'; Name = 'empty-subnet-id'; Kind = 'Network'; Empty = 'subnetID'; Error = $waiting }
    @{ Api = 'bucket'; Name = 'empty-provider-config'; Kind = 'Space'; Empty = 'providerConfigName'; Error = $waiting }
    @{ Api = 'bucket'; Name = 'empty-subscription-id'; Kind = 'Space'; Empty = 'subscriptionID'; Error = $waiting }
    @{ Api = 'secretstore'; Name = 'missing-network'; Kind = 'Network'; Remove = $true; Error = 'Network private-network not found' }
    @{ Api = 'secretstore'; Name = 'missing-space'; Kind = 'Space'; Remove = $true; Error = 'Space development not found' }
    @{ Api = 'secretstore'; Name = 'network-not-ready'; Kind = 'Network'; NotReady = $true }
    @{ Api = 'secretstore'; Name = 'space-not-ready'; Kind = 'Space'; NotReady = $true }
    @{ Api = 'secretstore'; Name = 'empty-subnet-id'; Kind = 'Network'; Empty = 'subnetID'; Error = $waiting }
    @{ Api = 'secretstore'; Name = 'empty-provider-config'; Kind = 'Space'; Empty = 'providerConfigName'; Error = $waiting }
    @{ Api = 'secretstore'; Name = 'missing-tenant'; Kind = 'EnvironmentConfig'; Field = 'tenantID'; Error = 'EnvironmentConfig azure must provide defaultLocation and tenantID' }
    @{ Api = 'app'; Name = 'missing-network'; Kind = 'Network'; Remove = $true; Error = 'Network private-network not found' }
    @{ Api = 'app'; Name = 'wrong-network-namespace'; Kind = 'Network'; WrongNamespace = $true; Error = 'Network private-network not found' }
    @{ Api = 'app'; Name = 'missing-space'; Kind = 'Space'; Remove = $true; Error = 'Space development not found' }
    @{ Api = 'app'; Name = 'wrong-space-namespace'; Kind = 'Space'; WrongNamespace = $true; Error = 'Space development not found' }
    @{ Api = 'app'; Name = 'missing-space-before-app'; Kind = 'Space'; Remove = $true; UsageOnly = $true; Error = 'Space development not found' }
    @{ Api = 'app'; Name = 'network-without-space'; Kind = 'Network'; Field = 'space'; Error = 'Network private-network must select a Space' }
    @{ Api = 'app'; Name = 'empty-subnet-id'; Kind = 'Network'; Empty = 'subnetID'; Error = $waiting }
    @{ Api = 'app'; Name = 'empty-provider-config'; Kind = 'Space'; Empty = 'providerConfigName'; Error = $waiting }
    @{ Api = 'app'; Name = 'empty-subscription-id'; Kind = 'Space'; Empty = 'subscriptionID'; Error = $waiting }
    @{ Api = 'app'; Name = 'missing-location'; Kind = 'EnvironmentConfig'; Field = 'defaultLocation'; Error = 'EnvironmentConfig azure must provide defaultLocation' }
    @{ Api = 'app'; Name = 'network-not-ready'; Kind = 'Network'; NotReady = $true }
    @{ Api = 'app'; Name = 'space-not-ready'; Kind = 'Space'; NotReady = $true }
    @{ Api = 'app'; Name = 'environment-not-ready'; Kind = 'Environment'; NotReady = $true }
    @{ Api = 'app'; Name = 'missing-environment-id'; Kind = 'Environment'; Field = 'id'; Error = 'waiting for App environment to publish its resource ID; keeping the private endpoint' }
    @{ Api = 'app'; Name = 'missing-environment-domain'; Kind = 'Environment'; Field = 'defaultDomain' }
)

$output = Join-Path ([System.IO.Path]::GetTempPath()) "crossplane-tests-$([guid]::NewGuid())"
$rendered = Join-Path $output 'rendered'
New-Item -ItemType Directory -Path $rendered -Force | Out-Null
try {
    foreach ($case in $cases) {
        Write-Host "Rendering $($case.Name)"
        $project = if ($case.ContainsKey('Project')) { $case.Project } else { $foundation }
        $api = Join-Path $project "apis\$($case.Api)"
        $fixture = Join-Path $project "tests\$($case.Api)"
        $requiredPath = Join-Path $fixture 'environment.yaml'
        if ($case.ContainsKey('ProviderName')) {
            $required = (Get-Content -LiteralPath $requiredPath -Raw).Replace('providerConfigName: development', "providerConfigName: $($case.ProviderName)")
            $requiredPath = Join-Path $output "$($case.Name)-required.yaml"
            Set-Content -LiteralPath $requiredPath -Value $required
        }
        $xrPath = Join-Path $project $case.XR
        if ($case.ContainsKey('Image')) {
            $updatedXR = (Get-Content -LiteralPath $xrPath -Raw).
                Replace('ghcr.io/pettertech/demo-app:1.0.2', $case.Image).
                Replace('targetPort: 8080', "targetPort: $($case.Port)")
            $xrPath = Join-Path $output "$($case.Name)-xr.yaml"
            Set-Content -LiteralPath $xrPath -Value $updatedXR
        }
        $arguments = @(
            'render'
            $xrPath
            (Join-Path $api 'composition.yaml')
            $functions
            "--crossplane-version=$crossplaneVersion"
            "--xrd=$(Join-Path $api 'definition.yaml')"
            "--required-resources=$requiredPath"
            '--include-full-xr'
        )
        if ($case.ContainsKey('Observed')) {
            $observedPath = Join-Path $project $case.Observed
            if ($case.ContainsKey('ObservedKinds')) {
                $observedDocuments = [regex]::Split((Get-Content -LiteralPath $observedPath -Raw), '(?m)^---\s*$')
                $selected = $observedDocuments | Where-Object {
                    $_ -match '(?m)^kind:\s+(\S+)\s*$' -and $Matches[1] -in $case.ObservedKinds
                }
                $observed = $selected -join "---`n"
                if ($case.ContainsKey('Public')) {
                    $observed = $observed.Replace('cacc58deefe15e43489e5b81', 'ca705d54aba52f80973c0809').Replace('hello', 'hello-public')
                }
                $observedPath = Join-Path $output "$($case.Name)-observed.yaml"
                Set-Content -LiteralPath $observedPath -Value $observed
            }
            $arguments += "--observed-resources=$observedPath"
        }
        $renderPath = Join-Path $rendered "$($case.Name).yaml"
        & crossplane @arguments > $renderPath
        if ($LASTEXITCODE -ne 0) {
            throw "Rendering $($case.Name) failed."
        }

        $renderedOutput = Get-Content -LiteralPath $renderPath -Raw
        if ($case.Name -eq 'space-ready') {
            $configs = @([regex]::Split($renderedOutput, '(?m)^---\s*$') | Where-Object {
                    $_ -match '(?m)^kind:\s+ProviderConfig\s*$'
                })
            if ($configs.Count -ne 1 -or $configs[0] -notmatch '(?m)^  storageUseAzureAD:\s+true\s*$') {
                throw 'Expected the Space ProviderConfig to use Azure AD for storage.'
            }
        }
        if ($case.ContainsKey('PrivateConnections')) {
            foreach ($kind in @('RoleAssignment', 'VirtualHubConnection')) {
                Assert-RenderedKind $renderedOutput $kind $case.PrivateConnections
            }
            $groupName = [regex]::Escape($case.ResourceGroup)
            if ($renderedOutput -notmatch "(?m)^    crossplane\.io/external-name:\s+$groupName\s*$") {
                throw "Expected resource group external name '$($case.ResourceGroup)'."
            }
            $groupReferences = [regex]::Matches($renderedOutput, '(?m)^    resourceGroupName:\s+(\S+)\s*$')
            if ($groupReferences.Count -ne 3) {
                throw "Expected three resource group references, found $($groupReferences.Count)."
            }
            foreach ($reference in $groupReferences) {
                if ($reference.Groups[1].Value -ne $case.ResourceGroup) {
                    throw "Expected resource group reference '$($case.ResourceGroup)', found '$($reference.Groups[1].Value)'."
                }
            }
        }
        if ($case.ContainsKey('ExpectedTags')) {
            $taggedKinds = if ($case.Api -eq 'bucket') {
                @('ResourceGroup', 'Account', 'PrivateEndpoint')
            }
            elseif ($case.Api -eq 'secretstore') {
                @('ResourceGroup', 'Vault', 'PrivateEndpoint')
            }
            elseif ($case.Api -eq 'app') {
                $case.AppKinds
            }
            else {
                @('ResourceGroup', 'VirtualNetwork', 'SecurityGroup')
            }
            Assert-RenderedTags $renderedOutput $taggedKinds $case.ExpectedTags
        }
        if ($case.ContainsKey('Replication')) {
            if ($renderedOutput -notmatch "(?m)^    accountReplicationType:\s+$($case.Replication)\s*$") {
                throw "Expected account replication $($case.Replication)."
            }
            if ($renderedOutput -notmatch '(?m)^  accountName:\s+st[0-9a-f]{22}\s*$') {
                throw 'Expected status.accountName to be a hashed storage account name.'
            }
            $containers = [regex]::Matches($renderedOutput, '(?m)^kind:\s+Container\s*$')
            if ($containers.Count -ne $case.Containers) {
                throw "Expected $($case.Containers) containers, found $($containers.Count)."
            }
            # Every Azure resource must use the Space's ProviderConfig.
            $configs = [regex]::Matches($renderedOutput, '(?m)^    kind: ProviderConfig\r?\n    name:\s+(\S+)\s*$')
            if ($configs.Count -ne 3 + $case.Containers) {
                throw "Expected $(3 + $case.Containers) ProviderConfig references, found $($configs.Count)."
            }
            foreach ($config in $configs) {
                if ($config.Groups[1].Value -ne 'development') {
                    throw "Expected ProviderConfig 'development', found '$($config.Groups[1].Value)'."
                }
            }
            Assert-RenderedKind $renderedOutput 'PrivateEndpoint' $true
            foreach ($setting in @(
                    'sharedAccessKeyEnabled: false'
                    'publicNetworkAccessEnabled: true'
                    'defaultToOauthAuthentication: true'
                    'allowNestedItemsToBePublic: false'
                    'httpsTrafficOnlyEnabled: true'
                    'minTlsVersion: TLS1_2'
                    'versioningEnabled: true'
                )) {
                if ($renderedOutput -notmatch "(?m)^ +$([regex]::Escape($setting))\s*$") {
                    throw "Bucket is missing hardening setting '$setting'."
                }
            }
            if ($renderedOutput -match '(?m)^ +networkRules:') {
                throw 'Bucket must not restrict provider data-plane access with network rules.'
            }
            if ($renderedOutput -notmatch '(?m)^    subnetId: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/network-private-network/providers/Microsoft.Network/virtualNetworks/network/subnets/default\s*$') {
                throw 'Bucket private endpoint must use the selected Network subnet.'
            }
            $privateContainers = [regex]::Matches($renderedOutput, '(?m)^    containerAccessType: private\s*$')
            $accountReferences = [regex]::Matches($renderedOutput, '(?m)^    storageAccountIdSelector:\r?\n      matchControllerRef: true\s*$')
            if ($privateContainers.Count -ne $case.Containers -or $accountReferences.Count -ne $case.Containers) {
                throw 'All Bucket containers must be private and select the account by controller reference.'
            }
            if ($renderedOutput -match '(?m)^    storageAccountId:') {
                throw 'Bucket containers must not copy the observed account ID.'
            }
        }
        if ($case.Name -eq 'secretstore') {
            Assert-RenderedKind $renderedOutput 'Vault' $false
        }
        if ($case.Name -eq 'secretstore-ready') {
            foreach ($setting in @(
                    'skuName: standard'
                    'rbacAuthorizationEnabled: true'
                    'purgeProtectionEnabled: true'
                    'softDeleteRetentionDays: 90'
                    'publicNetworkAccessEnabled: false'
                    'enabledForDeployment: false'
                    'enabledForDiskEncryption: false'
                    'enabledForTemplateDeployment: false'
                    'defaultAction: Deny'
                    'bypass: None'
                    'tenantId: 00000000-0000-4000-8000-000000000001'
                    'subnetId: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/network-private-network/providers/Microsoft.Network/virtualNetworks/network/subnets/default'
                    'resourceGroupName: secretstore-app-secrets'
                )) {
                if ($renderedOutput -notmatch "(?m)^ +$([regex]::Escape($setting))\s*$") {
                    throw "SecretStore is missing setting '$setting'."
                }
            }
            if ($renderedOutput -notmatch '(?m)^  vaultName:\s+kv[0-9a-f]{22}\s*$') {
                throw 'Expected status.vaultName to be a hashed Key Vault name.'
            }
            if ($renderedOutput -notmatch '(?m)^  privateEndpointID:\s+\S+\s*$') {
                throw 'Expected status.privateEndpointID.'
            }
            $configs = [regex]::Matches($renderedOutput, '(?m)^    kind: ProviderConfig\r?\n    name:\s+development\s*$')
            if ($configs.Count -ne 3) {
                throw "Expected three resources using ProviderConfig 'development', found $($configs.Count)."
            }
        }
        if ($case.Api -eq 'app') {
            foreach ($kind in @('ResourceGroup', 'Environment', 'ContainerApp', 'PrivateEndpoint')) {
                Assert-RenderedKind $renderedOutput $kind ($kind -in $case.AppKinds)
            }
            if ($case.Name -in @('app-ready', 'app-public-ready', 'app-public-updated', 'app-resolved-provider')) {
                $public = $case.ContainsKey('Public')
                $name = if ($public) { 'hello-public' } else { 'hello' }
                $seed = "00000000-0000-4000-8000-000000000010/team-a/$name"
                $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($seed))).ToLowerInvariant()
                $appName = "ca$($hash.Substring(0, 22))"
                $xr = Get-RenderedResource $renderedOutput 'App'
                $environment = Get-RenderedResource $renderedOutput 'Environment'
                $app = Get-RenderedResource $renderedOutput 'ContainerApp'
                $group = Get-RenderedResource $renderedOutput 'ResourceGroup'
                $access = if ($public) { 'Enabled' } else { 'Disabled' }
                $image = if ($case.ContainsKey('Image')) { $case.Image } else { 'ghcr.io/pettertech/demo-app:1.0.2' }
                $port = if ($case.ContainsKey('Port')) { $case.Port } else { 8080 }
                foreach ($setting in @("publicNetworkAccess: $access", 'workloadProfileType: Consumption', 'location: westeurope', "resourceGroupName: app-$name")) {
                    Assert-RenderedSetting $environment $setting
                }
                Assert-RenderedSetting $group "crossplane.io/external-name: app-$name"
                Assert-RenderedSetting $environment "crossplane.io/external-name: $appName-env"
                foreach ($setting in @(
                        "crossplane.io/external-name: $appName", "resourceGroupName: app-$name"
                        'workloadProfileName: Consumption', 'revisionMode: Single', 'type: SystemAssigned'
                        'externalEnabled: true', 'allowInsecureConnections: false', 'transport: auto'
                        'latestRevision: true', 'percentage: 100', "targetPort: $port"
                        'minReplicas: 1', 'maxReplicas: 3', 'concurrentRequests: "50"'
                        'cpu: 0.25', 'memory: 0.5Gi', "image: $image"
                    )) {
                    Assert-RenderedSetting $app $setting
                }
                if ($app -notmatch '(?m)^    containerAppEnvironmentIdSelector:\r?\n      matchControllerRef: true\s*$') {
                    throw 'App must select its environment by controller reference.'
                }
                foreach ($setting in @(
                        "appName: $appName"
                        'environmentDefaultDomain: example.westeurope.azurecontainerapps.io'
                        "fqdn: $appName.example.westeurope.azurecontainerapps.io"
                        "url: https://$appName.example.westeurope.azurecontainerapps.io"
                        'principalID: 00000000-0000-4000-8000-000000000020'
                        "environmentID: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/app-$name/providers/Microsoft.App/managedEnvironments/$appName-env"
                        "resourceID: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/app-$name/providers/Microsoft.App/containerApps/$appName"
                    )) {
                    Assert-RenderedSetting $xr $setting
                }
                if ($xr -notmatch '(?m)^    status: "True"\r?\n    type: Ready\s*$') {
                    throw 'Expected the fully observed App to be Ready.'
                }
                $providerName = if ($case.ContainsKey('ProviderName')) { $case.ProviderName } else { 'development' }
                $configs = [regex]::Matches($renderedOutput, "(?m)^    kind: ProviderConfig\r?\n    name:\s+$providerName\s*$")
                if ($configs.Count -ne $case.AppKinds.Count -or $renderedOutput -match 'ClusterProviderConfig|managementPolicies:|infrastructureSubnetId:') {
                    throw 'App resources must use the Space ProviderConfig, delete by default, and have no infrastructure subnet.'
                }
                if (-not $public) {
                    $endpoint = Get-RenderedResource $renderedOutput 'PrivateEndpoint'
                    foreach ($setting in @(
                            'subnetId: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/network-private-network/providers/Microsoft.Network/virtualNetworks/network/subnets/default'
                            "privateConnectionResourceId: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/app-$name/providers/Microsoft.App/managedEnvironments/$appName-env"
                            'isManualConnection: false', '- managedEnvironments'
                        )) {
                        Assert-RenderedSetting $endpoint $setting
                    }
                    Assert-RenderedSetting $xr 'privateEndpointIPAddress: 10.0.0.4'
                    Assert-RenderedSetting $xr "privateEndpointID: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/app-$name/providers/Microsoft.Network/privateEndpoints/$appName-env-pe"
                }
                elseif ($xr -match 'privateEndpointID:|privateEndpointIPAddress:') {
                    throw 'Public App must not publish private endpoint outputs.'
                }
                foreach ($kind in @('Environment', 'ContainerApp', 'PrivateEndpoint')) {
                    if ($kind -notin $case.AppKinds) { continue }
                    $usages = @([regex]::Split($renderedOutput, '(?m)^---\s*$') | Where-Object {
                            $_ -match '(?m)^kind:\s+Usage\s*$' -and $_ -match "(?m)^    kind: $kind\s*$"
                        })
                    if ($usages.Count -eq 0 -or ($usages -join "`n") -notmatch 'replayDeletion: true') {
                        throw "Expected sequenced v2 dependency Usages for $kind."
                    }
                }
            }
        }
    }

    $landingZoneKinds = @('Space', 'Network', 'Bucket', 'SecretStore')
    $landingZoneCases = @(
        @{ Name = 'initial'; ObservedKinds = @(); Kinds = @('Space') }
        @{ Name = 'space-ready'; ObservedKinds = @('Space'); Kinds = @('Space', 'Network') }
        @{ Name = 'network-ready'; ObservedKinds = @('Space', 'Network'); Kinds = $landingZoneKinds }
        @{ Name = 'bucket-ready'; ObservedKinds = @('Space', 'Network', 'Bucket'); Kinds = $landingZoneKinds }
        @{ Name = 'secretstore-ready'; ObservedKinds = @('Space', 'Network', 'SecretStore'); Kinds = $landingZoneKinds }
        @{ Name = 'ready'; ObservedKinds = $landingZoneKinds; Kinds = $landingZoneKinds; Ready = $true }
        @{ Name = 'public-ready'; ObservedKinds = $landingZoneKinds; Kinds = $landingZoneKinds; Ready = $true; Public = $true }
    )
    $requiredOutputs = @{
        Space = @('subscriptionID', 'providerConfigName')
        Network = @('subnetID')
        Bucket = @('accountName', 'blobEndpoint')
        SecretStore = @('vaultName', 'vaultURI')
    }
    foreach ($kind in $landingZoneKinds) {
        foreach ($fault in @('NotReady', 'NoCondition') + $requiredOutputs[$kind]) {
            $landingZoneCases += @{
                Name = "$kind-$fault-regression"; ObservedKinds = $landingZoneKinds
                Kinds = $landingZoneKinds; FaultKind = $kind; Fault = $fault
            }
        }
        foreach ($field in $requiredOutputs[$kind]) {
            $landingZoneCases += @{
                Name = "$kind-$field-missing"; ObservedKinds = $landingZoneKinds
                Kinds = $landingZoneKinds; FaultKind = $kind; Fault = $field; RemoveOutput = $true
            }
        }
    }
    $landingZoneCases += @(
        @{
            Name = 'space-missing-provider'; ObservedKinds = @('Space'); Kinds = @('Space')
            FaultKind = 'Space'; Fault = 'providerConfigName'
        }
        @{
            Name = 'network-missing-subnet'; ObservedKinds = @('Space', 'Network'); Kinds = @('Space', 'Network')
            FaultKind = 'Network'; Fault = 'subnetID'
        }
    )
    $landingZoneApi = Join-Path $stacks 'apis\landingzone'
    $landingZoneObserved = Get-Content -LiteralPath (Join-Path $stacks 'tests\landingzone\observed-ready.yaml') -Raw
    foreach ($case in $landingZoneCases) {
        Write-Host "Rendering LandingZone $($case.Name)"
        $public = $case.ContainsKey('Public')
        $zoneName = if ($public) { 'production' } else { 'development' }
        $exposure = if ($public) { 'public' } else { 'private' }
        $size = if ($public) { 'large' } else { 'medium' }
        $geo = if ($public) { 'true' } else { 'false' }
        $observed = $landingZoneObserved
        if ($public) {
            $observed = $observed.Replace('development', 'production').
                Replace('Development', 'Production').Replace('exposure: private', 'exposure: public')
        }
        $documents = [regex]::Split($observed, '(?m)^---\s*$')
        $selected = foreach ($document in $documents) {
            if ($document -notmatch '(?m)^kind:\s+(\S+)\s*$' -or $Matches[1] -notin $case.ObservedKinds) {
                continue
            }
            if ($case.ContainsKey('FaultKind') -and $document -match "(?m)^kind: $($case.FaultKind)\s*$") {
                $document = switch ($case.Fault) {
                    'NotReady' { $document.Replace('status: "True"', 'status: "False"') }
                    'NoCondition' { $document -replace '(?m)^  conditions:[^\r\n]*(\r?\n|$)', '' }
                    default {
                        if ($case.ContainsKey('RemoveOutput')) {
                            $document -replace "(?m)^  $($case.Fault):[^\r\n]*(\r?\n|$)", ''
                        }
                        else {
                            $document -replace "(?m)^(  $($case.Fault):)[^\r\n]*", '$1 ""'
                        }
                    }
                }
            }
            $document
        }
        $observedPath = Join-Path $output 'landingzone-observed.yaml'
        Set-Content -LiteralPath $observedPath -Value ($selected -join "---`n")
        $renderPath = Join-Path $rendered "landingzone-$($case.Name).yaml"
        $arguments = @(
            'render', (Join-Path $stacks "examples\landingzone-$exposure.yaml")
            (Join-Path $landingZoneApi 'composition.yaml'), $functions
            "--crossplane-version=$crossplaneVersion"
            "--xrd=$(Join-Path $landingZoneApi 'definition.yaml')"
            '--include-full-xr'
        )
        if ($case.ObservedKinds.Count -gt 0) { $arguments += "--observed-resources=$observedPath" }
        & crossplane @arguments > $renderPath
        if ($LASTEXITCODE -ne 0) { throw "Rendering LandingZone $($case.Name) failed." }
        $result = Get-Content -LiteralPath $renderPath -Raw
        $xr = Get-RenderedResource $result 'LandingZone'
        $ready = $xr -match '(?m)^    status: "True"\r?\n    type: Ready\s*$'
        if ($ready -ne $case.ContainsKey('Ready')) {
            throw "Unexpected LandingZone readiness for $($case.Name)."
        }
        $documents = [regex]::Split($result, '(?m)^---\s*$')
        foreach ($document in $documents) {
            if ($document -match '(?m)^kind:\s+(\S+)\s*$' -and $Matches[1] -notin ($landingZoneKinds + @('LandingZone', 'Usage'))) {
                throw "Unexpected resource kind in LandingZone: $($Matches[1])."
            }
        }
        foreach ($kind in $landingZoneKinds) {
            Assert-RenderedKind $result $kind ($kind -in $case.Kinds)
            if ($kind -notin $case.Kinds) { continue }
            $child = Get-RenderedResource $result $kind
            foreach ($setting in @("name: $zoneName", 'namespace: team-a', 'owner: team-a', "environment: $zoneName")) {
                if ($child -notmatch "(?m)^  (?:  )?$([regex]::Escape($setting))\s*$") {
                    throw "LandingZone $kind is missing metadata or tag '$setting'."
                }
            }
            if ($child -notmatch "(?m)^  ownerReferences:\r?\n  - apiVersion: platform.example.org/v1alpha1\r?\n    blockOwnerDeletion: true\r?\n    controller: true\r?\n    kind: LandingZone\r?\n    name: $zoneName\s*$") {
                throw "Expected LandingZone controller reference on $kind."
            }
            if ($child -match 'providerConfig|ClusterProviderConfig|compositionRef|credentials:') {
                throw 'LandingZone must not pass provider plumbing to children.'
            }
            switch ($kind) {
                Space {
                    $displayName = if ($public) { 'Production' } else { 'Development' }
                    Assert-RenderedSetting $child "displayName: $displayName"
                    Assert-RenderedSetting $child "exposure: $exposure"
                }
                Network {
                    Assert-RenderedSetting $child "space: $zoneName"
                    Assert-RenderedSetting $child "size: $size"
                }
                Bucket {
                    Assert-RenderedSetting $child "network: $zoneName"
                    Assert-RenderedSetting $child "geoRedundant: $geo"
                    $containers = @(if ($public) { 'incoming'; 'archive' } else { 'default' })
                    if ([regex]::Matches($child, '(?m)^  - name:').Count -ne $containers.Count) {
                        throw 'Unexpected LandingZone Bucket containers.'
                    }
                    foreach ($container in $containers) { Assert-RenderedSetting $child "name: $container" }
                }
                SecretStore { Assert-RenderedSetting $child "network: $zoneName" }
            }
        }
        if (-not $case.ContainsKey('Ready')) { continue }
        foreach ($setting in @(
                "spaceName: $zoneName", "networkName: $zoneName"
                'subscriptionID: 00000000-0000-4000-8000-000000000010'
                "subnetID: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/network-$zoneName/providers/Microsoft.Network/virtualNetworks/network/subnets/default"
                'accountName: st0000000000000000000001'
                'blobEndpoint: https://st0000000000000000000001.blob.core.windows.net/'
                'vaultName: kv0000000000000000000001'
                'vaultURI: https://kv0000000000000000000001.vault.azure.net/'
            )) {
            Assert-RenderedSetting $xr $setting
        }
        $usages = @($documents | Where-Object { $_ -match '(?m)^kind: Usage\s*$' })
        if ($usages.Count -ne 3) { throw "Expected three LandingZone Usages, found $($usages.Count)." }
        foreach ($edge in @(@('Network', 'Space'), @('Bucket', 'Network'), @('SecretStore', 'Network'))) {
            $usage = @($usages | Where-Object {
                    $_ -match "(?m)^  by:\r?\n    apiVersion: platform.example.org/v1alpha1\r?\n    kind: $($edge[0])\r?\n    resourceRef:\r?\n      name: $zoneName\s*$" -and
                    $_ -match "(?m)^  of:\r?\n    apiVersion: platform.example.org/v1alpha1\r?\n    kind: $($edge[1])\r?\n    resourceRef:\r?\n      name: $zoneName\s*$"
                })
            if ($usage.Count -ne 1) { throw "Missing LandingZone dependency $($edge -join ' -> ')." }
            if ($usage[0] -notmatch '(?m)^apiVersion: protection.crossplane.io/v1beta1\s*$') {
                throw 'Expected a namespaced v2 Usage.'
            }
            Assert-RenderedSetting $usage[0] 'replayDeletion: true'
        }

        foreach ($kind in $landingZoneKinds) {
            Write-Host "Rendering LandingZone $exposure child $kind"
            $apiName = $kind.ToLowerInvariant()
            $project = if ($kind -in @('Space', 'Network')) { $foundation } else { $services }
            $childApi = Join-Path $project "apis\$apiName"
            $fixture = Join-Path $project "tests\$apiName"
            $child = Get-RenderedResource $result $kind
            $childStatus = [regex]::Match((Get-RenderedResource $observed $kind), '(?ms)^status:.*$')
            if (-not $childStatus.Success) { throw "Missing observed LandingZone child status for $kind." }
            $child += "`n$($childStatus.Value)"
            $childPath = Join-Path $output 'landingzone-child.yaml'
            Set-Content -LiteralPath $childPath -Value $child
            $environment = Get-RenderedResource (Get-Content -LiteralPath (Join-Path $fixture 'environment.yaml') -Raw) 'EnvironmentConfig'
            $required = @($environment)
            foreach ($dependency in @('Space', 'Network')) {
                if ($dependency -eq $kind) { continue }
                $required += Get-RenderedResource $observed $dependency
            }
            $requiredPath = Join-Path $output 'landingzone-child-required.yaml'
            Set-Content -LiteralPath $requiredPath -Value ($required -join "---`n")
            $childObserved = (Get-Content -LiteralPath (Join-Path $fixture 'observed-ready.yaml') -Raw).
                Replace('private-network', $zoneName).Replace('reports', $zoneName).Replace('app-secrets', $zoneName).
                Replace('00000000-0000-4000-8000-000000000008', '00000000-0000-4000-8000-000000000010').
                Replace('subscriptionId: "00000000-0000-4000-8000-000000000001"', 'subscriptionId: "00000000-0000-4000-8000-000000000010"')
            $seed = "00000000-0000-4000-8000-000000000010/team-a/$zoneName"
            $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($seed))).ToLowerInvariant().Substring(0, 22)
            $childObserved = $childObserved -replace 'st[0-9a-f]{22}', "st$hash" -replace 'kv[0-9a-f]{22}', "kv$hash"
            $childObservedPath = Join-Path $output 'landingzone-child-observed.yaml'
            Set-Content -LiteralPath $childObservedPath -Value $childObserved
            $childRenderPath = Join-Path $rendered "landingzone-$exposure-$apiName.yaml"
            & crossplane render $childPath (Join-Path $childApi 'composition.yaml') $functions `
                "--crossplane-version=$crossplaneVersion" "--xrd=$(Join-Path $childApi 'definition.yaml')" `
                "--required-resources=$requiredPath" "--observed-resources=$childObservedPath" `
                --include-full-xr > $childRenderPath
            if ($LASTEXITCODE -ne 0) { throw "Rendering LandingZone child $kind failed." }
            $childResult = Get-Content -LiteralPath $childRenderPath -Raw
            switch ($kind) {
                Space {
                    Assert-RenderedSetting $childResult "managementGroupId: /providers/Microsoft.Management/managementGroups/$(if ($public) { 'online' } else { 'corp' })"
                }
                Network {
                    Assert-RenderedKind $childResult 'VirtualHubConnection' (-not $public)
                    Assert-RenderedSetting $childResult "numberOfIpAddresses: `"$(if ($public) { '512' } else { '256' })`""
                }
                Bucket {
                    Assert-RenderedSetting $childResult "accountReplicationType: $(if ($public) { 'GZRS' } else { 'ZRS' })"
                    Assert-RenderedSetting $childResult "subnetId: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/network-$zoneName/providers/Microsoft.Network/virtualNetworks/network/subnets/default"
                    foreach ($container in $containers) { Assert-RenderedSetting $childResult "crossplane.io/external-name: $container" }
                }
                SecretStore {
                    Assert-RenderedSetting $childResult "subnetId: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/network-$zoneName/providers/Microsoft.Network/virtualNetworks/network/subnets/default"
                }
            }
            if ($kind -in @('Bucket', 'SecretStore')) {
                $configs = [regex]::Matches($childResult, '(?m)^    kind: ProviderConfig\r?\n    name: (\S+)\s*$')
                if ($configs.Count -lt 3 -or @($configs | Where-Object { $_.Groups[1].Value -ne $zoneName }).Count -gt 0) {
                    throw "LandingZone $kind must use its Space's ProviderConfig."
                }
                Assert-RenderedTags $childResult @('ResourceGroup') @{ owner = 'platform'; 'managed-by' = 'crossplane'; environment = $zoneName }
            }
        }
    }

    foreach ($case in $dependencies) {
        Write-Host "Checking $($case.Api) dependency: $($case.Name)"
        $fixture = Join-Path $services "tests\$($case.Api)"
        $required = Get-Content -LiteralPath (Join-Path $fixture 'environment.yaml') -Raw
        $observed = Get-Content -LiteralPath (Join-Path $fixture 'observed-ready.yaml') -Raw
        $isObserved = $case.Kind -in @('Account', 'Environment', 'ContainerApp', 'PrivateEndpoint')
        $source = if ($isObserved) { $observed } else { $required }
        $documents = [regex]::Split($source, '(?m)^---\s*$')
        $matchedDocuments = 0
        $changed = foreach ($document in $documents) {
            if ($document -notmatch "(?m)^kind: $($case.Kind)\s*$") {
                $document
                continue
            }
            $matchedDocuments++
            if ($case.ContainsKey('Remove')) {
                continue
            }
            if ($case.ContainsKey('Field')) {
                $updated = $document -replace "(?m)^ +$($case.Field):[^\r\n]*(\r?\n|$)", ''
            }
            elseif ($case.ContainsKey('Empty')) {
                $updated = $document -replace "(?m)^( +$($case.Empty):)[^\r\n]*", '$1 ""'
            }
            elseif ($case.ContainsKey('WrongNamespace')) {
                $updated = $document.Replace('namespace: team-a', 'namespace: another-team')
            }
            else {
                $updated = $document.Replace('status: "True"', 'status: "False"')
            }
            if ($updated -eq $document) {
                throw "Failure fixture $($case.Name) did not change its $($case.Kind)."
            }
            $updated
        }
        $modified = $changed -join "---`n"
        if ($matchedDocuments -ne 1) {
            throw "Failure fixture $($case.Name) must match exactly one $($case.Kind)."
        }
        if ($isObserved) {
            $observed = $modified
        }
        else {
            $required = $modified
        }
        if ($case.ContainsKey('UsageOnly')) {
            $observed = ([regex]::Split($observed, '(?m)^---\s*$'))[0]
        }
        $requiredPath = Join-Path $output 'required.yaml'
        $observedPath = Join-Path $output 'observed.yaml'
        $errorPath = Join-Path $output 'failure.txt'
        Set-Content -LiteralPath $requiredPath -Value $required
        Set-Content -LiteralPath $observedPath -Value $observed
        & crossplane render (Join-Path $services "examples\$($case.Api).yaml") `
            (Join-Path $services "apis\$($case.Api)\composition.yaml") $functions `
            "--crossplane-version=$crossplaneVersion" `
            "--xrd=$(Join-Path $services "apis\$($case.Api)\definition.yaml")" `
            "--required-resources=$requiredPath" "--observed-resources=$observedPath" `
            > $errorPath 2>&1
        if (-not $case.ContainsKey('Error')) {
            if ($LASTEXITCODE -ne 0) {
                throw "$($case.Api) dependency $($case.Name) failed: $(Get-Content -LiteralPath $errorPath -Raw)"
            }
            $renderedOutput = Get-Content -LiteralPath $errorPath -Raw
            $lastKind = if ($case.Api -eq 'bucket') { 'Container' } else { 'PrivateEndpoint' }
            Assert-RenderedKind $renderedOutput $lastKind $true
            if ($case.Api -eq 'app') {
                foreach ($kind in @('ResourceGroup', 'Environment', 'ContainerApp', 'PrivateEndpoint')) {
                    Assert-RenderedKind $renderedOutput $kind $true
                }
            }
            continue
        }
        if ($LASTEXITCODE -eq 0) {
            throw "$($case.Api) failure $($case.Name) unexpectedly rendered successfully."
        }
        if ((Get-Content -LiteralPath $errorPath -Raw) -notmatch [regex]::Escape($case.Error)) {
            throw "$($case.Api) failure $($case.Name) did not report '$($case.Error)': $(Get-Content -LiteralPath $errorPath -Raw)"
        }
    }

    Write-Host 'Validating examples and rendered resources'
    # The CLI's built-in schema bundle omits namespaced Usages.
    $usageSchema = Join-Path $output 'usage.yaml'
    Invoke-WebRequest `
        -Uri "https://raw.githubusercontent.com/crossplane/crossplane/$crossplaneVersion/cluster/crds/protection.crossplane.io_usages.yaml" `
        -OutFile $usageSchema
    $extensions = @(
        $providers
        $usageSchema
        (Join-Path $foundation 'apis\space\definition.yaml')
        (Join-Path $foundation 'apis\network\definition.yaml')
        (Join-Path $services 'apis\bucket\definition.yaml')
        (Join-Path $services 'apis\secretstore\definition.yaml')
        (Join-Path $services 'apis\app\definition.yaml')
        (Join-Path $landingZoneApi 'definition.yaml')
    ) -join ','
    $resources = @(
        (Join-Path $foundation 'examples')
        (Join-Path $services 'examples')
        (Join-Path $stacks 'examples')
        $rendered
    ) -join ','
    & crossplane resource validate $extensions $resources `
        "--crossplane-image=xpkg.crossplane.io/crossplane/crossplane:$crossplaneVersion" `
        --error-on-missing-schemas
    if ($LASTEXITCODE -ne 0) {
        throw 'Resource validation failed.'
    }

    Write-Host 'Checking Bucket container input limits'
    foreach ($count in @(0, 20, 21)) {
        $containerEntries = $(for ($index = 0; $index -lt $count; $index++) { "    - name: container-$index" }) -join "`n"
        $containerSpec = if ($count -eq 0) { '  containers: []' } else { "  containers:`n$containerEntries" }
        $xr = @"
apiVersion: platform.example.org/v1alpha1
kind: Bucket
metadata:
  name: container-limits
  namespace: team-a
spec:
  network: private-network
$containerSpec
"@
        $xrPath = Join-Path $output 'container-limits.yaml'
        $validationPath = Join-Path $output 'container-validation.txt'
        Set-Content -LiteralPath $xrPath -Value $xr
        & crossplane resource validate (Join-Path $services 'apis\bucket\definition.yaml') `
            $xrPath "--crossplane-image=xpkg.crossplane.io/crossplane/crossplane:$crossplaneVersion" `
            --error-on-missing-schemas > $validationPath 2>&1
        $valid = $LASTEXITCODE -eq 0
        if ($valid -ne ($count -eq 20)) {
            throw "Unexpected validation result for $count containers: $(Get-Content -LiteralPath $validationPath -Raw)"
        }
        if (-not $valid -and (Get-Content -LiteralPath $validationPath -Raw) -notmatch 'containers') {
            throw "Expected a containers validation error: $(Get-Content -LiteralPath $validationPath -Raw)"
        }
    }

    Write-Host 'Checking Bucket tag key length limits'
    foreach ($length in @(128, 129)) {
        $tagKey = 'a' * $length
        $xr = @"
apiVersion: platform.example.org/v1alpha1
kind: Bucket
metadata:
  name: tag-key-limits
  namespace: team-a
spec:
  network: private-network
  containers:
    - name: data
  tags:
    ${tagKey}: test
"@
        $xrPath = Join-Path $output 'tag-key-limits.yaml'
        $validationPath = Join-Path $output 'tag-key-validation.txt'
        Set-Content -LiteralPath $xrPath -Value $xr
        & crossplane resource validate (Join-Path $services 'apis\bucket\definition.yaml') `
            $xrPath "--crossplane-image=xpkg.crossplane.io/crossplane/crossplane:$crossplaneVersion" `
            --error-on-missing-schemas > $validationPath 2>&1
        $valid = $LASTEXITCODE -eq 0
        if ($valid -ne ($length -eq 128)) {
            throw "Unexpected validation result for a $length-character tag key: $(Get-Content -LiteralPath $validationPath -Raw)"
        }
        if (-not $valid -and (Get-Content -LiteralPath $validationPath -Raw) -notmatch 'Tag keys must be 1-128 characters') {
            throw "Expected a tag key length validation error: $(Get-Content -LiteralPath $validationPath -Raw)"
        }
    }

    Write-Host 'Checking App input boundaries'
    $digest = 'a' * 64
    $appInputs = @(
        @{ Name = 'version-tag'; Image = 'ghcr.io/example/app:1.2.3'; Port = 8080; Valid = $true }
        @{ Name = 'digest'; Image = "ghcr.io/example/app@sha256:$digest"; Port = 8080; Valid = $true }
        @{ Name = 'minimum-port'; Image = 'example/app:1'; Port = 1; Valid = $true }
        @{ Name = 'maximum-port'; Image = 'example/app:1'; Port = 65535; Valid = $true }
        @{ Name = 'latest'; Image = 'example/app:latest'; Port = 8080; Valid = $false; Field = 'image' }
        @{ Name = 'implicit-latest'; Image = 'example/app'; Port = 8080; Valid = $false; Field = 'image' }
        @{ Name = 'registry-port-is-not-tag'; Image = 'registry.example.org:5000/app'; Port = 8080; Valid = $false; Field = 'image' }
        @{ Name = 'short-digest'; Image = 'example/app@sha256:abc'; Port = 8080; Valid = $false; Field = 'image' }
        @{ Name = 'non-hex-digest'; Image = "example/app@sha256:$('g' * 64)"; Port = 8080; Valid = $false; Field = 'image' }
        @{ Name = 'empty-tag'; Image = 'example/app:'; Port = 8080; Valid = $false; Field = 'image' }
        @{ Name = 'zero-port'; Image = 'example/app:1'; Port = 0; Valid = $false; Field = 'targetPort' }
        @{ Name = 'large-port'; Image = 'example/app:1'; Port = 65536; Valid = $false; Field = 'targetPort' }
        @{ Name = 'invalid-exposure'; Image = 'example/app:1'; Port = 8080; Exposure = 'internal'; Valid = $false; Field = 'exposure' }
        @{ Name = 'missing-network'; Image = 'example/app:1'; Port = 8080; Remove = 'network'; Valid = $false; Field = 'network' }
        @{ Name = 'missing-image'; Image = 'example/app:1'; Port = 8080; Remove = 'image'; Valid = $false; Field = 'image' }
        @{ Name = 'missing-spec'; Image = 'example/app:1'; Port = 8080; Remove = 'spec'; Valid = $false; Field = 'spec' }
    )
    foreach ($case in $appInputs) {
        $exposure = if ($case.ContainsKey('Exposure')) { $case.Exposure } else { 'private' }
        $xr = @"
apiVersion: platform.example.org/v1alpha1
kind: App
metadata:
  name: input-boundaries
  namespace: team-a
spec:
  network: private-network
  image: "$($case.Image)"
  targetPort: $($case.Port)
  exposure: $exposure
"@
        if ($case.ContainsKey('Remove')) {
            $xr = if ($case.Remove -eq 'spec') {
                ($xr -split '(?m)^spec:')[0]
            }
            else {
                $xr -replace "(?m)^  $($case.Remove):[^\r\n]*(\r?\n|$)", ''
            }
        }
        $xrPath = Join-Path $output 'app-input.yaml'
        $validationPath = Join-Path $output 'app-validation.txt'
        Set-Content -LiteralPath $xrPath -Value $xr
        & crossplane resource validate (Join-Path $services 'apis\app\definition.yaml') `
            $xrPath "--crossplane-image=xpkg.crossplane.io/crossplane/crossplane:$crossplaneVersion" `
            --error-on-missing-schemas > $validationPath 2>&1
        if (($LASTEXITCODE -eq 0) -ne $case.Valid) {
            throw "Unexpected App validation result for $($case.Name): $(Get-Content -LiteralPath $validationPath -Raw)"
        }
        if (-not $case.Valid -and (Get-Content -LiteralPath $validationPath -Raw) -notmatch $case.Field) {
            throw "Expected App $($case.Field) validation error: $(Get-Content -LiteralPath $validationPath -Raw)"
        }
    }

    Write-Host 'Checking LandingZone input boundaries'
    $landingZoneInputs = @(
        @{ Name = 'defaults'; Valid = $true }
        @{ Name = 'missing-spec'; Remove = 'spec'; Valid = $false; Field = 'spec' }
        @{ Name = 'missing-display-name'; Remove = 'displayName'; Valid = $false; Field = 'displayName' }
        @{ Name = 'missing-exposure'; Remove = 'exposure'; Valid = $false; Field = 'exposure' }
        @{ Name = 'invalid-exposure'; Exposure = 'internal'; Valid = $false; Field = 'exposure' }
        @{ Name = 'small-network'; Extra = '  networkSize: small'; Valid = $true }
        @{ Name = 'invalid-size'; Extra = '  networkSize: enormous'; Valid = $false; Field = 'networkSize' }
        @{ Name = 'invalid-geo'; Extra = '  geoRedundant: "yes"'; Valid = $false; Field = 'geoRedundant' }
        @{ Name = 'minimum-name'; ResourceName = 'a'; Valid = $true }
        @{ Name = 'maximum-name'; ResourceName = ('a' * 63); Valid = $true }
        @{ Name = 'long-name'; ResourceName = ('a' * 64); Valid = $false; Field = 'name' }
        @{ Name = 'short-display-name'; DisplayName = 'ab'; Valid = $false; Field = 'displayName' }
        @{ Name = 'display-name-whitespace'; DisplayName = 'a b'; Valid = $false; Field = 'displayName' }
        @{ Name = 'long-display-name'; DisplayName = ('a' * 65); Valid = $false; Field = 'displayName' }
        @{ Name = 'invalid-container'; Extra = "  containers:`n    - name: bad--name"; Valid = $false; Field = 'containers' }
        @{ Name = 'duplicate-container'; Extra = "  containers:`n    - name: data`n    - name: data"; Valid = $false; Field = 'containers' }
    )
    foreach ($count in @(0, 1, 20, 21)) {
        $entries = $(for ($index = 0; $index -lt $count; $index++) { "    - name: container-$index" }) -join "`n"
        $extra = if ($count -eq 0) { '  containers: []' } else { "  containers:`n$entries" }
        $landingZoneInputs += @{ Name = "$count-containers"; Extra = $extra; Valid = $count -in @(1, 20); Field = 'containers' }
    }
    foreach ($key in @(('a' * 128), ('a' * 129), 'invalid/key', '')) {
        $landingZoneInputs += @{
            Name = "tag-key-$($key.Length)"; Extra = "  tags:`n    `"$key`": value"
            Valid = $key.Length -eq 128; Field = 'tags'
        }
    }
    foreach ($count in @(40, 41)) {
        $entries = $(for ($index = 0; $index -lt $count; $index++) { "    tag-$index`: value" }) -join "`n"
        $landingZoneInputs += @{ Name = "$count-tags"; Extra = "  tags:`n$entries"; Valid = $count -eq 40; Field = 'tags' }
    }
    foreach ($length in @(256, 257)) {
        $landingZoneInputs += @{
            Name = "tag-value-$length"; Extra = "  tags:`n    owner: $('a' * $length)"
            Valid = $length -eq 256; Field = 'tags'
        }
    }
    foreach ($case in $landingZoneInputs) {
        $name = if ($case.ContainsKey('ResourceName')) { $case.ResourceName } else { 'input-boundaries' }
        $displayName = if ($case.ContainsKey('DisplayName')) { $case.DisplayName } else { 'Development' }
        $exposure = if ($case.ContainsKey('Exposure')) { $case.Exposure } else { 'private' }
        $xr = @"
apiVersion: platform.example.org/v1alpha1
kind: LandingZone
metadata:
  name: $name
  namespace: team-a
spec:
  displayName: "$displayName"
  exposure: $exposure
"@
        if ($case.ContainsKey('Extra')) { $xr += "`n$($case.Extra)`n" }
        if ($case.ContainsKey('Remove')) {
            $xr = if ($case.Remove -eq 'spec') { ($xr -split '(?m)^spec:')[0] }
            else { $xr -replace "(?m)^  $($case.Remove):[^\r\n]*(\r?\n|$)", '' }
        }
        $xrPath = Join-Path $output 'landingzone-input.yaml'
        $validationPath = Join-Path $output 'landingzone-validation.txt'
        Set-Content -LiteralPath $xrPath -Value $xr
        & crossplane resource validate (Join-Path $landingZoneApi 'definition.yaml') `
            $xrPath "--crossplane-image=xpkg.crossplane.io/crossplane/crossplane:$crossplaneVersion" `
            --error-on-missing-schemas > $validationPath 2>&1
        if (($LASTEXITCODE -eq 0) -ne $case.Valid) {
            throw "Unexpected LandingZone validation result for $($case.Name): $(Get-Content -LiteralPath $validationPath -Raw)"
        }
        if (-not $case.Valid -and (Get-Content -LiteralPath $validationPath -Raw) -notmatch $case.Field) {
            throw "Expected LandingZone $($case.Field) validation error: $(Get-Content -LiteralPath $validationPath -Raw)"
        }
    }

    Write-Host 'All render and validation checks passed.'
}
finally {
    Remove-Item -LiteralPath $output -Recurse -Force
}
