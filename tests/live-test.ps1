#Requires -Version 7.0
<#
.SYNOPSIS
Runs live checks against a cluster with the starter pack installed and Azure.

.DESCRIPTION
Run one phase at a time. verify and negative change nothing in Azure. day2
changes the existing LandingZone and reverts it. app, standalone and public
create billed Azure resources; delete removes only what those phases created.
See tests/README.md for details.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('verify', 'negative', 'day2', 'app', 'standalone', 'public', 'delete')]
    [string]$Phase,
    [string]$Namespace = 'team-a',
    [string]$LandingZone = 'development',
    [string]$StandaloneNamespace = 'team-b',
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Get-Command kubectl, az -ErrorAction Stop | Out-Null

$root = Split-Path $PSScriptRoot -Parent
$publicLandingZone = 'production'
$apps = @{ 'livetest-private' = 'private'; 'livetest-public' = 'public' }
$prefixLengths = @{ small = 25; medium = 24; large = 23 }
$script:failures = 0

# --- Output and assertions -----------------------------------------------------

function Write-Step([string]$Message) { Write-Host "`n== $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "  WARN $Message" -ForegroundColor Yellow }

function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) {
        Write-Host "  PASS $Message" -ForegroundColor Green
    } else {
        Write-Host "  FAIL $Message" -ForegroundColor Red
        $script:failures++
    }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    Assert-That ("$Actual" -eq "$Expected") "$Message (expected '$Expected', got '$Actual')"
}

# --- Running kubectl and az ----------------------------------------------------

function Invoke-ToolResult([string]$Tool, [string[]]$Arguments, [string]$InputText) {
    $output = if ($InputText) { $InputText | & $Tool @Arguments 2>&1 } else { & $Tool @Arguments 2>&1 }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n"); Stdout = $stdout }
}

function Invoke-Tool([string]$Tool, [string[]]$Arguments, [string]$InputText) {
    $result = Invoke-ToolResult $Tool $Arguments $InputText
    $attempt = 0
    while ($result.ExitCode -ne 0 -and $result.Output -match 'ServiceUnavailable' -and $attempt -lt 3) {
        $attempt++
        Start-Sleep -Seconds 5
        $result = Invoke-ToolResult $Tool $Arguments $InputText
    }
    if ($result.ExitCode -ne 0) { throw "$Tool $($Arguments -join ' ') failed:`n$($result.Output)" }
    return $result.Stdout
}

function Get-Json([string]$Tool, [string[]]$Arguments) {
    $text = Invoke-Tool $Tool $Arguments
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -AsHashtable
}

function Get-K8s([string]$Resource, [string]$Name, [string]$Ns) {
    $arguments = @('get', $Resource, $Name, '-o', 'json')
    if ($Ns) { $arguments += @('-n', $Ns) }
    return Get-Json kubectl $arguments
}

function Test-K8sExists([string]$Resource, [string]$Name, [string]$Ns) {
    $arguments = @('get', $Resource, $Name, '--ignore-not-found', '-o', 'name')
    if ($Ns) { $arguments += @('-n', $Ns) }
    $output = Invoke-Tool kubectl $arguments
    return $output.Trim() -ne ''
}

function Get-K8sOrNull([string]$Resource, [string]$Name, [string]$Ns) {
    if (Test-K8sExists $Resource $Name $Ns) { return Get-K8s $Resource $Name $Ns }
    return $null
}

function Get-Az([string[]]$Arguments) {
    return Get-Json az ($Arguments + @('--only-show-errors', '-o', 'json'))
}

function Set-Manifest([string]$Yaml) {
    Invoke-Tool kubectl @('apply', '-f', '-') $Yaml | Write-Host
}

function Update-AzSubscriptions {
    # New subscriptions are invisible to --subscription until the CLI cache is refreshed.
    Invoke-Tool az @('account', 'list', '--refresh', '--only-show-errors', '-o', 'none') | Out-Null
}

# --- Waiting -------------------------------------------------------------------

function Wait-Until([scriptblock]$Condition, [int]$Minutes = $TimeoutMinutes, [int]$IntervalSeconds = 20) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return $true } } catch { Write-Verbose $_ }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

function Wait-Ready([string]$Resource, [string]$Name, [string]$Ns) {
    Write-Host "  waiting up to $TimeoutMinutes minutes for $Resource/$Name to be Ready"
    Invoke-Tool kubectl @('wait', "$Resource/$Name", '-n', $Ns, '--for=condition=Ready', "--timeout=$($TimeoutMinutes)m") | Out-Null
}

function Remove-Foreground([string]$Resource, [string]$Name, [string]$Ns) {
    Write-Host "  deleting $Resource/$Name in $Ns"
    Invoke-Tool kubectl @('delete', $Resource, $Name, '-n', $Ns, '--cascade=foreground', '--ignore-not-found', "--timeout=$($TimeoutMinutes)m") | Out-Null
}

# --- Shared checks -------------------------------------------------------------

function Get-Condition($Object, [string]$Type) {
    $condition = @($Object.status.conditions | Where-Object { $_.type -eq $Type })
    if ($condition.Count -eq 0) { return $null }
    return $condition[0].status
}

function Assert-Healthy($Object) {
    $label = "$($Object.kind)/$($Object.metadata.name)"
    Assert-Equal (Get-Condition $Object 'Ready') 'True' "$label is Ready"
    Assert-Equal (Get-Condition $Object 'Synced') 'True' "$label is Synced"
}

function Assert-StatusFields($Object, [string[]]$Fields) {
    foreach ($field in $Fields) {
        Assert-That (-not [string]::IsNullOrEmpty($Object.status[$field])) "$($Object.kind) status.$field is set"
    }
}

function Get-IdPart([string]$Id, [int]$Index) { return ($Id -split '/')[$Index] }

function Get-RoleAssignments([string]$PrincipalId, [string]$Subscription) {
    $assignments = Get-Az @('role', 'assignment', 'list', '--assignee-object-id', $PrincipalId, '--all',
        '--include-inherited', '--subscription', $Subscription)
    return @($assignments | ForEach-Object { "$($_.roleDefinitionName) @ $($_.scope)" } | Sort-Object)
}

function Assert-Tags([string]$ResourceId, $UserTags) {
    $expected = @{}
    foreach ($key in $UserTags.Keys) { $expected[$key] = $UserTags[$key] }
    foreach ($key in $environment.platformTags.Keys) { $expected[$key] = $environment.platformTags[$key] }
    $actual = Get-Az @('resource', 'show', '--ids', $ResourceId, '--query', 'tags')
    if (-not $actual) { $actual = @{} }
    $name = Get-IdPart $ResourceId -1
    foreach ($key in $expected.Keys) {
        Assert-Equal $actual[$key] $expected[$key] "$name has tag $key"
    }
}

function Assert-PrivateEndpoint([string]$EndpointId, [string]$SubnetId) {
    $endpoint = Get-Az @('network', 'private-endpoint', 'show', '--ids', $EndpointId)
    $name = Get-IdPart $EndpointId -1
    Assert-Equal $endpoint.subnet.id $SubnetId "$name is in the Network subnet"
    Assert-Equal $endpoint.provisioningState 'Succeeded' "$name is provisioned"
    $zoneGroups = @(Get-Az @('network', 'private-endpoint', 'dns-zone-group', 'list', '--endpoint-name', $name,
            '-g', (Get-IdPart $EndpointId 4), '--subscription', (Get-IdPart $EndpointId 2)))
    if ($zoneGroups.Count -eq 0) { Write-Warn "$name has no DNS zone group yet; check the private DNS policy" }
}

function Test-Space([string]$Ns, [string]$Name, [string]$Exposure, $Tags) {
    Write-Step "Space $Ns/$Name"
    Update-AzSubscriptions
    $space = Get-K8s space $Name $Ns
    Assert-Healthy $space
    Assert-StatusFields $space @('subscriptionID', 'providerConfigName')
    $subscription = $space.status.subscriptionID
    $identity = $space.status.identity

    $providerConfig = Get-K8s providerconfigs.azure.m.upbound.io $space.status.providerConfigName $Ns
    Assert-Equal $providerConfig.spec.clientID $identity.clientID 'ProviderConfig uses the Space identity'
    Assert-Equal $providerConfig.spec.subscriptionID $subscription 'ProviderConfig targets the Space subscription'
    Assert-Equal $providerConfig.spec.credentials.source 'OIDCTokenFile' 'ProviderConfig uses Workload Identity'

    $group = if ($Exposure -eq 'private') { 'corp' } else { 'online' }
    $managementGroup = Get-IdPart $environment.managementGroupIds[$group] -1
    $association = Invoke-ToolResult az @('account', 'management-group', 'subscription', 'show',
        '--name', $managementGroup, '--subscription', $subscription, '--only-show-errors', '-o', 'none')
    Assert-Equal $association.ExitCode 0 "Subscription is in management group $managementGroup"

    foreach ($namespace in 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault', 'Microsoft.Compute', 'Microsoft.App') {
        $state = Invoke-Tool az @('provider', 'show', '-n', $namespace, '--subscription', $subscription,
            '--query', 'registrationState', '-o', 'tsv', '--only-show-errors')
        Assert-Equal $state.Trim() 'Registered' "$namespace is registered"
    }

    $credentials = @(Get-Az @('identity', 'federated-credential', 'list', '--identity-name', (Get-IdPart $identity.resourceID 8),
            '-g', (Get-IdPart $identity.resourceID 4), '--subscription', (Get-IdPart $identity.resourceID 2)))
    Assert-Equal $credentials.Count 1 'Identity has one federated credential'
    if ($credentials.Count -eq 1) {
        Assert-Equal $credentials[0].issuer $environment.oidcIssuerURL 'Federated credential issuer'
        Assert-Equal $credentials[0].subject 'system:serviceaccount:crossplane-system:provider-azure' 'Federated credential subject'
    }
    Assert-Tags $identity.resourceID $Tags

    $poolSubscription = Get-IdPart $environment.ipamPoolID 2
    Assert-Equal (@(Get-RoleAssignments $identity.principalID $subscription) -join ', ') "Owner @ /subscriptions/$subscription" `
        'Identity has only Owner in its subscription'
    Assert-Equal (@(Get-RoleAssignments $identity.principalID $poolSubscription) -join ', ') "IPAM Pool User @ $($environment.ipamPoolID)" `
        'Identity has only IPAM Pool User in the pool (and hub) subscription'
    return $space
}

function Test-Network([string]$Ns, [string]$Name, [string]$Size, [string]$Exposure, $Tags) {
    Write-Step "Network $Ns/$Name"
    $network = Get-K8s network $Name $Ns
    Assert-Healthy $network
    Assert-StatusFields $network @('resourceID', 'subnetID')
    $vnetId = $network.status.resourceID

    $vnet = Get-Az @('network', 'vnet', 'show', '--ids', $vnetId)
    $prefix = @($vnet.addressSpace.addressPrefixes)
    Assert-Equal $prefix.Count 1 'VNet has one address prefix'
    Assert-That ($prefix[0].EndsWith("/$($prefixLengths[$Size])")) "VNet is /$($prefixLengths[$Size]) ($($prefix[0]))"
    Assert-Equal (@($vnet.subnets).Count) 1 'VNet has one subnet'
    $subnet = Get-Az @('network', 'vnet', 'subnet', 'show', '--ids', $network.status.subnetID)
    Assert-Equal $subnet.addressPrefix $prefix[0] 'Subnet uses the whole allocation'
    Assert-Equal (Get-IdPart $subnet.networkSecurityGroup.id -1) 'network' 'Subnet has the network NSG'
    Assert-Tags $vnetId $Tags

    $hub = $environment.virtualHubID
    $connections = @(Get-Az @('network', 'vhub', 'connection', 'list', '-g', (Get-IdPart $hub 4), '--vhub-name', (Get-IdPart $hub 8),
            '--subscription', (Get-IdPart $hub 2)) | Where-Object { $_.remoteVirtualNetwork.id -eq $vnetId })
    $grants = @(Get-Az @('role', 'assignment', 'list', '--assignee-object-id', $environment.platformPrincipalID,
            '--scope', $vnetId, '--subscription', (Get-IdPart $vnetId 2)) | Where-Object { $_.roleDefinitionName -eq 'Network Contributor' })
    if ($Exposure -eq 'private') {
        Assert-Equal $connections.Count 1 'VNet has one hub connection'
        if ($connections.Count -eq 1) { Assert-Equal $connections[0].provisioningState 'Succeeded' 'Hub connection succeeded' }
        Assert-Equal $grants.Count 1 'Platform identity has Network Contributor on the VNet'
    } else {
        Assert-Equal $connections.Count 0 'VNet has no hub connection'
        Assert-Equal $grants.Count 0 'Platform identity has no grant on the VNet'
    }
    return $network
}

function Test-Bucket([string]$Ns, [string]$Name, $Network, [string[]]$Containers, [bool]$GeoRedundant, $Tags) {
    Write-Step "Bucket $Ns/$Name"
    $bucket = Get-K8s bucket $Name $Ns
    Assert-Healthy $bucket
    Assert-StatusFields $bucket @('accountName', 'resourceID', 'blobEndpoint')
    $accountId = $bucket.status.resourceID

    $account = Get-Az @('storage', 'account', 'show', '--ids', $accountId)
    Assert-Equal $account.sku.name ($GeoRedundant ? 'Standard_GZRS' : 'Standard_ZRS') 'Storage SKU'
    Assert-Equal $account.allowSharedKeyAccess $false 'Shared keys are off'
    Assert-Equal $account.allowBlobPublicAccess $false 'Anonymous blob access is off'
    Assert-Equal $account.minimumTlsVersion 'TLS1_2' 'Minimum TLS version'
    Assert-Tags $accountId $Tags

    $blob = Get-Az @('storage', 'account', 'blob-service-properties', 'show', '--account-name', $account.name,
        '-g', $account.resourceGroup, '--subscription', (Get-IdPart $accountId 2))
    Assert-Equal $blob.isVersioningEnabled $true 'Blob versioning is on'
    Assert-Equal $blob.deleteRetentionPolicy.days 7 'Blob soft delete days'

    $actual = @(Get-AzContainers $accountId) -join ','
    Assert-Equal $actual ((@($Containers) | Sort-Object) -join ',') 'Containers match spec'
    $endpointId = "/subscriptions/$(Get-IdPart $accountId 2)/resourceGroups/$($account.resourceGroup)/providers/Microsoft.Network/privateEndpoints/$($account.name)-blob"
    Assert-PrivateEndpoint $endpointId $Network.status.subnetID
    return $bucket
}

function Get-AzContainers([string]$AccountId) {
    return @(Get-Az @('storage', 'container-rm', 'list', '--storage-account', (Get-IdPart $AccountId 8), '-g', (Get-IdPart $AccountId 4),
            '--subscription', (Get-IdPart $AccountId 2), '--query', '[].name') | Sort-Object)
}

function Test-SecretStore([string]$Ns, [string]$Name, $Network, $Tags) {
    Write-Step "SecretStore $Ns/$Name"
    $store = Get-K8s secretstore $Name $Ns
    Assert-Healthy $store
    Assert-StatusFields $store @('vaultName', 'resourceID', 'vaultURI', 'privateEndpointID')

    $vault = Get-Az @('keyvault', 'show', '-n', $store.status.vaultName, '--subscription', (Get-IdPart $store.status.resourceID 2))
    Assert-Equal $vault.properties.publicNetworkAccess 'Disabled' 'Vault public access is off'
    Assert-Equal $vault.properties.enableRbacAuthorization $true 'Vault uses Azure RBAC'
    Assert-Equal $vault.properties.enablePurgeProtection $true 'Vault purge protection is on'
    Assert-Equal $vault.properties.softDeleteRetentionInDays 90 'Vault soft delete days'
    Assert-Equal $vault.properties.networkAcls.bypass 'None' 'Vault allows no trusted-service bypass'
    Assert-Tags $store.status.resourceID $Tags
    Assert-PrivateEndpoint $store.status.privateEndpointID $Network.status.subnetID
    return $store
}

function Test-LandingZone([string]$Ns, [string]$Name) {
    Write-Step "LandingZone $Ns/$Name"
    $lz = Get-K8s landingzone $Name $Ns
    Assert-Healthy $lz
    Assert-StatusFields $lz @('spaceName', 'networkName', 'subscriptionID', 'subnetID', 'accountName', 'blobEndpoint', 'vaultName', 'vaultURI')
    $spec = $lz.spec

    $space = Test-Space $Ns $Name $spec.exposure $spec.tags
    $network = Test-Network $Ns $Name $spec.networkSize $spec.exposure $spec.tags
    $bucket = Test-Bucket $Ns $Name $network @($spec.containers | ForEach-Object { $_.name }) $spec.geoRedundant $spec.tags
    $store = Test-SecretStore $Ns $Name $network $spec.tags

    Write-Step "LandingZone $Ns/$Name status matches its children"
    Assert-Equal $lz.status.subscriptionID $space.status.subscriptionID 'subscriptionID'
    Assert-Equal $lz.status.subnetID $network.status.subnetID 'subnetID'
    Assert-Equal $lz.status.accountName $bucket.status.accountName 'accountName'
    Assert-Equal $lz.status.blobEndpoint $bucket.status.blobEndpoint 'blobEndpoint'
    Assert-Equal $lz.status.vaultName $store.status.vaultName 'vaultName'
    Assert-Equal $lz.status.vaultURI $store.status.vaultURI 'vaultURI'
}

function Assert-Rejected([string]$Description, [string[]]$Arguments, [string]$InputText, [string]$Expected) {
    $result = Invoke-ToolResult kubectl $Arguments $InputText
    $matched = $result.ExitCode -ne 0 -and $result.Output -like "*$Expected*"
    Assert-That $matched "Rejected: $Description"
    if (-not $matched) { Write-Host "    kubectl said: $($result.Output)" }
}

function Assert-AzureCleanup($Space, $Network, $Store) {
    if (-not ($Space -and $Space.status.subscriptionID -and $Space.status.identity)) {
        Write-Warn 'Space never published a subscription and identity; skipping Azure cleanup checks'
        return
    }
    $Subscription = $Space.status.subscriptionID
    $Identity = $Space.status.identity
    Write-Step "Azure cleanup for subscription $Subscription"
    $identityResult = Invoke-ToolResult az @('identity', 'show', '--ids', $Identity.resourceID, '--only-show-errors', '-o', 'none')
    Assert-That ($identityResult.ExitCode -ne 0) 'Space identity is deleted'
    Assert-Equal @(Get-RoleAssignments $Identity.principalID (Get-IdPart $environment.ipamPoolID 2)).Count 0 'Identity has no pool access left'

    if ($Network -and $Network.status.resourceID) {
        $hub = $environment.virtualHubID
        $connections = @(Get-Az @('network', 'vhub', 'connection', 'list', '-g', (Get-IdPart $hub 4), '--vhub-name', (Get-IdPart $hub 8),
                '--subscription', (Get-IdPart $hub 2)) | Where-Object { $_.remoteVirtualNetwork.id -eq $Network.status.resourceID })
        Assert-Equal $connections.Count 0 'No hub connection remains'
    }

    if ($Store -and $Store.status.vaultName) {
        $vaultName = $Store.status.vaultName
        $deletedVaults = @(Get-Az @('keyvault', 'list-deleted', '--resource-type', 'vault', '--subscription', $Subscription,
                '--query', "[?name=='$vaultName'].name"))
        Assert-Equal $deletedVaults.Count 1 "Vault $vaultName is soft-deleted and recoverable"
    }

    Update-AzSubscriptions
    $cancelled = Wait-Until -Minutes 15 {
        (Invoke-Tool az @('account', 'show', '--subscription', $Subscription, '--query', 'state', '-o', 'tsv', '--only-show-errors')).Trim() -in 'Disabled', 'Deleted'
    }
    $state = (Invoke-Tool az @('account', 'show', '--subscription', $Subscription, '--query', 'state', '-o', 'tsv', '--only-show-errors')).Trim()
    Assert-That $cancelled "Subscription is cancelled (state $state)"
}

function Get-ManagedNames([string]$Ns, [string]$Prefix) {
    $names = Invoke-Tool kubectl @('get', 'managed,usages.protection.crossplane.io,providerconfigs.azure.m.upbound.io', '-n', $Ns, '-o', 'name')
    return @($names -split "`n" | Where-Object { $_ -and ($_ -split '/')[-1] -like "*$Prefix*" })
}

# --- Manifests -----------------------------------------------------------------

function New-LandingZoneJson([hashtable]$Spec, [string]$Name = 'livetest-invalid') {
    $base = @{ displayName = 'LiveTest'; exposure = 'private' }
    foreach ($key in $Spec.Keys) { $base[$key] = $Spec[$key] }
    return @{ apiVersion = 'platform.example.org/v1alpha1'; kind = 'LandingZone'
        metadata = @{ name = $Name; namespace = $Namespace }; spec = $base
    } | ConvertTo-Json -Depth 10
}

function New-AppYaml([string]$Name, [string]$Exposure, [string]$Image = 'ghcr.io/pettertech/demo-app:1.0.2', [string]$Port = '8080') {
    return @"
apiVersion: platform.example.org/v1alpha1
kind: App
metadata:
  name: $Name
  namespace: $Namespace
spec:
  network: $LandingZone
  image: $Image
  targetPort: $Port
  exposure: $Exposure
  tags:
    owner: $Namespace
    purpose: livetest
"@
}

$standaloneTags = @{ owner = $StandaloneNamespace; purpose = 'livetest' }
$standaloneYaml = @"
apiVersion: platform.example.org/v1alpha1
kind: Space
metadata:
  name: development
  namespace: $StandaloneNamespace
spec:
  displayName: LiveTest-$StandaloneNamespace
  exposure: private
  tags:
    owner: $StandaloneNamespace
    purpose: livetest
---
apiVersion: platform.example.org/v1alpha1
kind: Network
metadata:
  name: private-network
  namespace: $StandaloneNamespace
spec:
  space: development
  size: small
  tags:
    owner: $StandaloneNamespace
    purpose: livetest
---
apiVersion: platform.example.org/v1alpha1
kind: Bucket
metadata:
  name: reports
  namespace: $StandaloneNamespace
spec:
  network: private-network
  containers:
    - name: incoming
    - name: archive
  tags:
    owner: $StandaloneNamespace
    purpose: livetest
---
apiVersion: platform.example.org/v1alpha1
kind: SecretStore
metadata:
  name: app-secrets
  namespace: $StandaloneNamespace
spec:
  network: private-network
  tags:
    owner: $StandaloneNamespace
    purpose: livetest
"@

$publicYaml = @"
apiVersion: platform.example.org/v1alpha1
kind: LandingZone
metadata:
  name: $publicLandingZone
  namespace: $Namespace
spec:
  displayName: LiveTest-Production
  exposure: public
  networkSize: large
  geoRedundant: true
  containers:
    - name: incoming
    - name: archive
  tags:
    owner: $Namespace
    environment: production
    purpose: livetest
"@

# --- Phases --------------------------------------------------------------------

$environment = (Get-K8s environmentconfig azure).data
Write-Host "Context: $(Invoke-Tool kubectl @('config', 'current-context'))  Phase: $Phase"

switch ($Phase) {
    'verify' {
        Test-LandingZone $Namespace $LandingZone
    }

    'negative' {
        Write-Step 'Immutable LandingZone fields (server-side dry run)'
        $lz = Get-K8s landingzone $LandingZone $Namespace
        $otherExposure = if ($lz.spec.exposure -eq 'private') { 'public' } else { 'private' }
        $otherSize = if ($lz.spec.networkSize -eq 'small') { 'medium' } else { 'small' }
        $patches = @(
            @{ Field = 'exposure'; Patch = @{ exposure = $otherExposure }; Expected = 'Exposure cannot change' }
            @{ Field = 'networkSize'; Patch = @{ networkSize = $otherSize }; Expected = 'Network size cannot change' }
            @{ Field = 'geoRedundant'; Patch = @{ geoRedundant = -not $lz.spec.geoRedundant }; Expected = 'geoRedundant cannot change' }
        )
        foreach ($case in $patches) {
            $patch = @{ spec = $case.Patch } | ConvertTo-Json -Compress
            Assert-Rejected "change $($case.Field)" @('patch', 'landingzone', $LandingZone, '-n', $Namespace,
                '--type', 'merge', '-p', $patch, '--dry-run=server') $null $case.Expected
        }

        Write-Step 'Invalid LandingZone input (server-side dry run)'
        $tooManyTags = @{}; 1..41 | ForEach-Object { $tooManyTags["k$_"] = 'v' }
        $invalid = @(
            @{ Description = 'empty containers'; Spec = @{ containers = @() }; Expected = 'at least 1' }
            @{ Description = 'duplicate containers'; Spec = @{ containers = @(@{ name = 'same' }, @{ name = 'same' }) }; Expected = 'Duplicate value' }
            @{ Description = 'invalid container name'; Spec = @{ containers = @(@{ name = 'Bad_Name' }) }; Expected = 'should match' }
            @{ Description = 'more than 40 tags'; Spec = @{ tags = $tooManyTags }; Expected = 'at most 40' }
            @{ Description = 'tag key with /'; Spec = @{ tags = @{ 'a/b' = 'v' } }; Expected = 'Tag keys must be' }
            @{ Description = 'displayName with a space'; Spec = @{ displayName = 'Has space' }; Expected = 'should match' }
            @{ Description = 'unknown exposure'; Spec = @{ exposure = 'internal' }; Expected = 'Unsupported value' }
            @{ Description = 'unknown networkSize'; Spec = @{ networkSize = 'huge' }; Expected = 'Unsupported value' }
            @{ Description = 'user-supplied providerConfigRef'; Spec = @{ providerConfigRef = @{ name = 'default' } }; Expected = 'unknown field' }
        )
        foreach ($case in $invalid) {
            Assert-Rejected $case.Description @('apply', '-f', '-', '--dry-run=server', '--validate=strict') (New-LandingZoneJson $case.Spec) $case.Expected
        }

        Write-Step 'Usages protect dependencies (server-side dry run)'
        Assert-Rejected 'delete a Network that services use' @('delete', 'network', $LandingZone, '-n', $Namespace, '--dry-run=server') $null 'in-use by'
        Assert-Rejected 'delete a Space that a Network uses' @('delete', 'space', $LandingZone, '-n', $Namespace, '--dry-run=server') $null 'in-use by'

        if (Test-K8sExists xrd apps.platform.example.org '') {
            Write-Step 'Invalid App input (server-side dry run)'
            $appCases = @(
                @{ Description = 'latest image tag'; Image = 'ghcr.io/pettertech/demo-app:latest'; Port = '8080'; Expected = 'must not use latest' }
                @{ Description = 'untagged image'; Image = 'ghcr.io/pettertech/demo-app'; Port = '8080'; Expected = 'explicit version tag' }
                @{ Description = 'malformed digest'; Image = 'ghcr.io/pettertech/demo-app@sha256:abc'; Port = '8080'; Expected = 'explicit version tag' }
                @{ Description = 'port 0'; Image = 'ghcr.io/pettertech/demo-app:1.0.2'; Port = '0'; Expected = 'greater than or equal to 1' }
            )
            foreach ($case in $appCases) {
                Assert-Rejected $case.Description @('apply', '-f', '-', '--dry-run=server') (New-AppYaml 'livetest-invalid' 'private' $case.Image $case.Port) $case.Expected
            }
        } else {
            Write-Warn 'App API is not installed; skipping App input checks (the app phase installs it)'
        }

        Write-Step 'Bucket with a missing Network fails without creating Azure resources'
        Set-Manifest @"
apiVersion: platform.example.org/v1alpha1
kind: Bucket
metadata:
  name: livetest-missing
  namespace: $Namespace
spec:
  network: livetest-does-not-exist
  containers:
    - name: default
"@
        $failed = Wait-Until -Minutes 5 -IntervalSeconds 10 { (Get-Condition (Get-K8s bucket livetest-missing $Namespace) 'Synced') -eq 'False' }
        $bucket = Get-K8s bucket livetest-missing $Namespace
        Assert-That $failed "Bucket is Synced=False ($(@($bucket.status.conditions | Where-Object type -eq 'Synced')[0].message))"
        Assert-That ((Get-Condition $bucket 'Ready') -ne 'True') 'Bucket is not Ready'
        Assert-Equal @(Get-ManagedNames $Namespace 'livetest-missing' | Where-Object { $_ -notlike 'usage*' }).Count 0 'No managed resources were created'
        Remove-Foreground bucket livetest-missing $Namespace
    }

    'day2' {
        $lz = Get-K8s landingzone $LandingZone $Namespace
        Assert-Healthy $lz
        $bucket = Get-K8s bucket $LandingZone $Namespace
        $store = Get-K8s secretstore $LandingZone $Namespace
        $network = Get-K8s network $LandingZone $Namespace
        $originalTags = @{}
        foreach ($key in $lz.spec.tags.Keys) { $originalTags[$key] = $lz.spec.tags[$key] }
        $tagged = @($bucket.status.resourceID, $store.status.resourceID, $network.status.resourceID)
        $before = Get-Json kubectl @('get', 'managed', '-n', $Namespace, '-o', 'json')
        $uids = @{}
        foreach ($item in $before.items) { $uids["$($item.kind)/$($item.metadata.name)"] = $item.metadata.uid }

        function Get-AzTag([string]$Id, [string]$Key) {
            $tags = Get-Az @('resource', 'show', '--ids', $Id, '--query', 'tags')
            if ($tags) { return $tags[$Key] }
        }
        function Set-LandingZoneSpec([hashtable]$Spec) {
            $patch = @{ spec = $Spec } | ConvertTo-Json -Depth 5 -Compress
            Invoke-Tool kubectl @('patch', 'landingzone', $LandingZone, '-n', $Namespace, '--type', 'merge', '-p', $patch) | Write-Host
        }

        Write-Step 'Add a tag and remove it again'
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        $testTagKey = "livetest-$stamp"
        $temporaryTags = @{} + $originalTags
        $temporaryTags[$testTagKey] = $stamp
        Set-LandingZoneSpec @{ tags = $temporaryTags }
        foreach ($id in $tagged) {
            Assert-That (Wait-Until -Minutes 15 { (Get-AzTag $id $testTagKey) -eq $stamp }) "$(Get-IdPart $id -1) gets tag $testTagKey"
        }
        Set-LandingZoneSpec @{ tags = @{ $testTagKey = $null } }
        foreach ($id in $tagged) {
            Assert-That (Wait-Until -Minutes 15 { $null -eq (Get-AzTag $id $testTagKey) }) "$(Get-IdPart $id -1) loses tag $testTagKey"
        }

        Write-Step 'Add a container and remove it again'
        $original = @($lz.spec.containers | ForEach-Object { $_.name })
        $testContainer = "livetest-$stamp"
        Set-LandingZoneSpec @{ containers = @($original + $testContainer | ForEach-Object { @{ name = $_ } }) }
        Assert-That (Wait-Until -Minutes 15 { $testContainer -in (Get-AzContainers $bucket.status.resourceID) }) "Container $testContainer is created"
        Set-LandingZoneSpec @{ containers = @($original | ForEach-Object { @{ name = $_ } }) }
        Assert-That (Wait-Until -Minutes 15 { $testContainer -notin (Get-AzContainers $bucket.status.resourceID) }) "Container $testContainer is deleted"
        Assert-Equal ((Get-AzContainers $bucket.status.resourceID) -join ',') (($original | Sort-Object) -join ',') 'Original containers are untouched'

        Write-Step 'Platform tags win over user tags'
        if ($environment.platformTags.Count -eq 0) {
            Write-Warn 'EnvironmentConfig has no platformTags; skipping'
        } else {
            $key = @($environment.platformTags.Keys)[0]
            $sentinel = "sentinel-$stamp"
            $precedenceTestKey = "livetest-$stamp"
            $overrideTags = @{} + $originalTags
            $overrideTags[$key] = 'user-override'
            $overrideTags[$precedenceTestKey] = $sentinel
            Set-LandingZoneSpec @{ tags = $overrideTags }
            foreach ($id in $tagged) {
                $applied = Wait-Until -Minutes 15 { (Get-AzTag $id $precedenceTestKey) -eq $sentinel }
                Assert-That $applied "$(Get-IdPart $id -1) received the update"
                Assert-Equal (Get-AzTag $id $key) $environment.platformTags[$key] "$(Get-IdPart $id -1) keeps platform tag $key"
            }
            $restoreTags = @{ $key = $null; $precedenceTestKey = $null }
            if ($originalTags.ContainsKey($key)) { $restoreTags[$key] = $originalTags[$key] }
            Set-LandingZoneSpec @{ tags = $restoreTags }
            foreach ($id in $tagged) {
                Assert-That (Wait-Until -Minutes 15 { $null -eq (Get-AzTag $id $precedenceTestKey) }) "$(Get-IdPart $id -1) loses tag $precedenceTestKey"
            }
        }

        Write-Step 'Nothing was replaced'
        Wait-Ready landingzone $LandingZone $Namespace
        $after = Get-Json kubectl @('get', 'managed', '-n', $Namespace, '-o', 'json')
        $afterUids = @{}
        foreach ($item in $after.items) { $afterUids["$($item.kind)/$($item.metadata.name)"] = $item.metadata.uid }
        $replaced = @($uids.Keys | Where-Object { $afterUids[$_] -ne $uids[$_] })
        Assert-That ($replaced.Count -eq 0) "Managed resources keep their UIDs $($replaced -join ', ')"
        Assert-Healthy (Get-K8s landingzone $LandingZone $Namespace)
    }

    'app' {
        if (-not (Test-K8sExists xrd apps.platform.example.org '')) {
            Write-Step 'Installing the App API'
            Invoke-Tool kubectl @('apply', '-f', (Join-Path $root 'projects\services\apis\app')) | Write-Host
            Invoke-Tool kubectl @('wait', 'xrd/apps.platform.example.org', '--for=condition=Established', '--timeout=5m') | Out-Null
        }
        $network = Get-K8s network $LandingZone $Namespace
        foreach ($name in $apps.Keys) { Set-Manifest (New-AppYaml $name $apps[$name]) }

        foreach ($name in $apps.Keys) {
            $exposure = $apps[$name]
            Write-Step "App $Namespace/$name ($exposure)"
            Wait-Ready app $name $Namespace
            $app = Get-K8s app $name $Namespace
            Assert-Healthy $app
            Assert-StatusFields $app @('appName', 'resourceID', 'environmentID', 'fqdn', 'url', 'principalID')

            $azureApp = Get-Az @('resource', 'show', '--ids', $app.status.resourceID)
            $ingress = $azureApp.properties.configuration.ingress
            Assert-Equal $ingress.external $true 'Ingress is external to the environment'
            Assert-Equal $ingress.allowInsecure $false 'Ingress is HTTPS only'
            Assert-Equal $ingress.targetPort 8080 'Target port'
            Assert-Equal $azureApp.properties.template.scale.minReplicas 1 'Min replicas'
            Assert-Equal $azureApp.properties.template.scale.maxReplicas 3 'Max replicas'
            Assert-Equal $azureApp.properties.template.containers[0].resources.cpu 0.25 'CPU'
            Assert-Equal $azureApp.properties.template.containers[0].resources.memory '0.5Gi' 'Memory'
            Assert-Equal $azureApp.identity.principalId $app.status.principalID 'System identity matches status'
            Assert-Tags $app.status.resourceID @{ owner = $Namespace; purpose = 'livetest' }

            $environmentResource = Get-Az @('resource', 'show', '--ids', $app.status.environmentID)
            $usage = @((Get-Json kubectl @('get', 'usages.protection.crossplane.io', '-n', $Namespace, '-o', 'json')).items | Where-Object {
                    $_.metadata.labels -and $_.metadata.labels['crossplane.io/composite'] -eq $name -and
                    $_.spec.of.kind -eq 'Network' -and $_.spec.of.resourceRef.name -eq $LandingZone })
            Assert-Equal $usage.Count 1 'A Usage protects the Network'

            $reachable = Wait-Until -Minutes ($exposure -eq 'public' ? 10 : 1) -IntervalSeconds 15 {
                $status = (Invoke-WebRequest -Uri $app.status.url -TimeoutSec 20 -SkipHttpErrorCheck).StatusCode
                $status -ge 200 -and $status -lt 300
            }
            if ($exposure -eq 'private') {
                Assert-Equal $environmentResource.properties.publicNetworkAccess 'Disabled' 'Environment public access is off'
                Assert-StatusFields $app @('privateEndpointID', 'privateEndpointIPAddress')
                Assert-PrivateEndpoint $app.status.privateEndpointID $network.status.subnetID
                Assert-That (-not $reachable) 'URL is not reachable from this machine over the internet'
            } else {
                Assert-Equal $environmentResource.properties.publicNetworkAccess 'Enabled' 'Environment public access is on'
                Assert-That (-not $app.status.ContainsKey('privateEndpointID') -or [string]::IsNullOrEmpty($app.status['privateEndpointID'])) 'No private endpoint'
                Assert-That $reachable "URL $($app.status.url) answers with 2xx"
            }

            $patch = @{ spec = @{ network = 'other'; exposure = ($exposure -eq 'public' ? 'private' : 'public') } } | ConvertTo-Json -Compress
            Assert-Rejected 'change network and exposure' @('patch', 'app', $name, '-n', $Namespace, '--type', 'merge', '-p', $patch, '--dry-run=server') `
                $null 'cannot change'
        }
    }

    'standalone' {
        Write-Step "Creating Space, Network, Bucket and SecretStore in $StandaloneNamespace"
        if (-not (Test-K8sExists namespace $StandaloneNamespace '')) { Invoke-Tool kubectl @('create', 'namespace', $StandaloneNamespace) | Write-Host }
        Set-Manifest $standaloneYaml
        Wait-Ready space development $StandaloneNamespace
        $space = Test-Space $StandaloneNamespace development private $standaloneTags
        Wait-Ready network private-network $StandaloneNamespace
        $network = Test-Network $StandaloneNamespace private-network small private $standaloneTags
        Wait-Ready bucket reports $StandaloneNamespace
        Wait-Ready secretstore app-secrets $StandaloneNamespace
        Test-Bucket $StandaloneNamespace reports $network @('incoming', 'archive') $false $standaloneTags | Out-Null
        Test-SecretStore $StandaloneNamespace app-secrets $network $standaloneTags | Out-Null

        Write-Step "Isolation between $Namespace and $StandaloneNamespace"
        $other = Get-K8s space $LandingZone $Namespace
        Assert-That ($space.status.subscriptionID -ne $other.status.subscriptionID) 'Spaces have separate subscriptions'
        Assert-That ($space.status.identity.resourceID -ne $other.status.identity.resourceID) 'Spaces have separate identities'
        Assert-Equal @(Get-RoleAssignments $space.status.identity.principalID $other.status.subscriptionID).Count 0 `
            "$StandaloneNamespace identity has no access to the $Namespace subscription"
        Assert-Equal @(Get-RoleAssignments $other.status.identity.principalID $space.status.subscriptionID).Count 0 `
            "$Namespace identity has no access to the $StandaloneNamespace subscription"
        $configs = @((Get-Json kubectl @('get', 'providerconfigs.azure.m.upbound.io', '-A', '-o', 'json')).items |
            Where-Object { $_.spec.clientID -eq $space.status.identity.clientID })
        Assert-That ($configs.Count -eq 1 -and $configs[0].metadata.namespace -eq $StandaloneNamespace) "Only $StandaloneNamespace has a ProviderConfig for its identity"
    }

    'public' {
        Write-Step "Creating LandingZone $Namespace/$publicLandingZone (public)"
        Set-Manifest $publicYaml
        Wait-Ready landingzone $publicLandingZone $Namespace
        Test-LandingZone $Namespace $publicLandingZone
    }

    'delete' {
        foreach ($name in $apps.Keys) {
            if (-not (Test-K8sExists app $name $Namespace)) { continue }
            Write-Step "Deleting App $Namespace/$name"
            $app = Get-K8s app $name $Namespace
            Remove-Foreground app $name $Namespace
            $groupName = Get-IdPart $app.status.resourceID 4
            $groupExists = (Invoke-Tool az @('group', 'exists', '--name', $groupName, '--subscription', (Get-IdPart $app.status.resourceID 2),
                    '--only-show-errors', '-o', 'tsv')).Trim()
            Assert-Equal $groupExists 'false' "Resource group $groupName is deleted"
            Assert-Equal @(Get-ManagedNames $Namespace $name).Count 0 'No managed resources, Usages or ProviderConfigs remain'
        }

        if (Test-K8sExists space development $StandaloneNamespace) {
            Write-Step "Deleting standalone resources in $StandaloneNamespace"
            $space = Get-K8sOrNull space development $StandaloneNamespace
            $network = Get-K8sOrNull network private-network $StandaloneNamespace
            $store = Get-K8sOrNull secretstore app-secrets $StandaloneNamespace
            Remove-Foreground bucket reports $StandaloneNamespace
            Remove-Foreground secretstore app-secrets $StandaloneNamespace
            Remove-Foreground network private-network $StandaloneNamespace
            Remove-Foreground space development $StandaloneNamespace
            Assert-Equal @(Get-ManagedNames $StandaloneNamespace '').Count 0 "$StandaloneNamespace has no managed resources, Usages or ProviderConfigs"
            Assert-AzureCleanup $space $network $store
            Write-Host "  leaving namespace $StandaloneNamespace intact; it may contain unrelated resources"
        }

        if (Test-K8sExists landingzone $publicLandingZone $Namespace) {
            Write-Step "Deleting LandingZone $Namespace/$publicLandingZone and recording the order"
            $space = Get-K8sOrNull space $publicLandingZone $Namespace
            $network = Get-K8sOrNull network $publicLandingZone $Namespace
            $store = Get-K8sOrNull secretstore $publicLandingZone $Namespace
            Invoke-Tool kubectl @('delete', 'landingzone', $publicLandingZone, '-n', $Namespace, '--cascade=foreground', '--wait=false') | Write-Host
            $gone = @{}
            Wait-Until -IntervalSeconds 15 {
                foreach ($kind in 'bucket', 'secretstore', 'network', 'space', 'landingzone') {
                    if (-not $gone.ContainsKey($kind) -and -not (Test-K8sExists $kind $publicLandingZone $Namespace)) {
                        $gone[$kind] = Get-Date
                        Write-Host "  $kind gone at $($gone[$kind].ToString('HH:mm:ss'))"
                    }
                }
                $gone.ContainsKey('landingzone')
            } | Out-Null
            Assert-That ($gone.Count -eq 5) 'LandingZone and all children are deleted'
            if ($gone.Count -eq 5 -and $network -and $store) {
                Assert-That ($gone.bucket -le $gone.network -and $gone.secretstore -le $gone.network) 'Bucket and SecretStore go before Network'
                Assert-That ($gone.network -le $gone.space) 'Network goes before Space'
            }
            Assert-Equal @(Get-ManagedNames $Namespace $publicLandingZone).Count 0 'No managed resources, Usages or ProviderConfigs remain'
            Assert-AzureCleanup $space $network $store
        }

        Write-Step "LandingZone $Namespace/$LandingZone is untouched"
        Assert-Healthy (Get-K8s landingzone $LandingZone $Namespace)
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$Phase finished with $($script:failures) failure(s)." -ForegroundColor Red
    exit 1
}
Write-Host "$Phase passed." -ForegroundColor Green
