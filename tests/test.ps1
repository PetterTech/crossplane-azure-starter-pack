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
)

$bucketFailures = @(
    @{ Name = 'missing-network'; Kind = 'Network'; Remove = $true; Error = 'Network private-network not found' }
    @{ Name = 'missing-space'; Kind = 'Space'; Remove = $true; Error = 'Space development not found' }
    @{ Name = 'missing-space-before-storage'; Kind = 'Space'; Remove = $true; UsageOnly = $true; Error = 'Space development not found' }
    @{ Name = 'network-not-ready'; Kind = 'Network'; NotReady = $true; Error = 'Network private-network is not Ready' }
    @{ Name = 'space-not-ready'; Kind = 'Space'; NotReady = $true; Error = 'Space development is not Ready' }
    @{ Name = 'missing-subnet'; Kind = 'Network'; Field = 'subnetID'; Error = 'Network private-network requires status.subnetID' }
    @{ Name = 'missing-provider-config'; Kind = 'Space'; Field = 'providerConfigName'; Error = 'Space development requires status.providerConfigName' }
    @{ Name = 'missing-subscription'; Kind = 'Space'; Field = 'subscriptionID'; Error = 'Space development requires status.subscriptionID' }
    @{ Name = 'missing-location'; Kind = 'EnvironmentConfig'; Field = 'defaultLocation'; Error = 'EnvironmentConfig azure requires defaultLocation' }
    @{ Name = 'missing-account-id'; Kind = 'Account'; Field = 'id'; Error = 'Storage account requires status.atProvider.id' }
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
        $arguments = @(
            'render'
            (Join-Path $project $case.XR)
            (Join-Path $api 'composition.yaml')
            $functions
            "--crossplane-version=$crossplaneVersion"
            "--xrd=$(Join-Path $api 'definition.yaml')"
            "--required-resources=$(Join-Path $fixture 'environment.yaml')"
            '--include-full-xr'
        )
        if ($case.ContainsKey('Observed')) {
            $arguments += "--observed-resources=$(Join-Path $project $case.Observed)"
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
                if ($config.Groups[1].Value -ne 'space-credentials') {
                    throw "Expected ProviderConfig 'space-credentials', found '$($config.Groups[1].Value)'."
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
            $accountReferences = [regex]::Matches($renderedOutput, '(?m)^    storageAccountId: /subscriptions/00000000-0000-4000-8000-000000000010/resourceGroups/bucket-reports/providers/Microsoft.Storage/storageAccounts/stb6858ae51a3bb88cef7fd3\s*$')
            if ($privateContainers.Count -ne $case.Containers -or $accountReferences.Count -ne $case.Containers) {
                throw 'All Bucket containers must be private and reference the observed account ID.'
            }
        }
    }

    foreach ($case in $bucketFailures) {
        Write-Host "Checking Bucket failure: $($case.Name)"
        $fixture = Join-Path $services 'tests\bucket'
        $required = Get-Content -LiteralPath (Join-Path $fixture 'environment.yaml') -Raw
        $observed = Get-Content -LiteralPath (Join-Path $fixture 'observed-ready.yaml') -Raw
        $source = if ($case.Kind -eq 'Account') { $observed } else { $required }
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
        if ($case.Kind -eq 'Account') {
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
        & crossplane render (Join-Path $services 'examples\bucket.yaml') `
            (Join-Path $services 'apis\bucket\composition.yaml') $functions `
            "--crossplane-version=$crossplaneVersion" `
            "--xrd=$(Join-Path $services 'apis\bucket\definition.yaml')" `
            "--required-resources=$requiredPath" "--observed-resources=$observedPath" `
            > $errorPath 2>&1
        if ($LASTEXITCODE -eq 0) {
            throw "Bucket failure $($case.Name) unexpectedly rendered successfully."
        }
        if ((Get-Content -LiteralPath $errorPath -Raw) -notmatch [regex]::Escape($case.Error)) {
            throw "Bucket failure $($case.Name) did not report '$($case.Error)': $(Get-Content -LiteralPath $errorPath -Raw)"
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
    ) -join ','
    $resources = @(
        (Join-Path $foundation 'examples')
        (Join-Path $services 'examples')
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

    Write-Host 'All render and validation checks passed.'
}
finally {
    Remove-Item -LiteralPath $output -Recurse -Force
}
