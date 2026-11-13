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
)

$output = Join-Path ([System.IO.Path]::GetTempPath()) "crossplane-tests-$([guid]::NewGuid())"
$rendered = Join-Path $output 'rendered'
New-Item -ItemType Directory -Path $rendered -Force | Out-Null
try {
    foreach ($case in $cases) {
        Write-Host "Rendering $($case.Name)"
        $api = Join-Path $foundation "apis\$($case.Api)"
        $fixture = Join-Path $foundation "tests\$($case.Api)"
        $arguments = @(
            'render'
            (Join-Path $foundation $case.XR)
            (Join-Path $api 'composition.yaml')
            $functions
            "--crossplane-version=$crossplaneVersion"
            "--xrd=$(Join-Path $api 'definition.yaml')"
            "--required-resources=$(Join-Path $fixture 'environment.yaml')"
            '--include-full-xr'
        )
        if ($case.ContainsKey('Observed')) {
            $arguments += "--observed-resources=$(Join-Path $foundation $case.Observed)"
        }
        $renderPath = Join-Path $rendered "$($case.Name).yaml"
        & crossplane @arguments > $renderPath
        if ($LASTEXITCODE -ne 0) {
            throw "Rendering $($case.Name) failed."
        }

        $renderedOutput = Get-Content -LiteralPath $renderPath -Raw
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
            Assert-RenderedTags $renderedOutput `
                @('ResourceGroup', 'VirtualNetwork', 'SecurityGroup') `
                $case.ExpectedTags
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
    ) -join ','
    $resources = @(
        (Join-Path $foundation 'examples')
        $rendered
    ) -join ','
    & crossplane resource validate $extensions $resources `
        "--crossplane-image=xpkg.crossplane.io/crossplane/crossplane:$crossplaneVersion" `
        --error-on-missing-schemas
    if ($LASTEXITCODE -ne 0) {
        throw 'Resource validation failed.'
    }

    Write-Host 'All render and validation checks passed.'
}
finally {
    Remove-Item -LiteralPath $output -Recurse -Force
}
