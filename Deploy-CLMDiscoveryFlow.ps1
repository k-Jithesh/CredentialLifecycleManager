<#
.SYNOPSIS
    Packs the Discovery-CLMCredentials flow into a solution zip and imports it
    into the target Dataverse / Power Platform environment using the Power Platform CLI (pac).

.DESCRIPTION
    Creates an unmanaged solution scaffold under .\out\flow-solution\, drops in:
      - A Workflows\<guid>.json envelope wrapping flows\Discovery-CLMCredentials\definition.json
      - Connection references from flows\Discovery-CLMCredentials\manifest.json
      - solution.xml + customizations.xml + [Content_Types].xml
    Then runs `pac solution pack` + `pac solution import`.

.PARAMETER EnvironmentUrl
    Dataverse environment URL, e.g. https://contoso.crm6.dynamics.com

.PARAMETER SolutionUniqueName
    Unique solution name. Default: clmDiscoveryFlow.

.PARAMETER PublisherPrefix
    Customization prefix. Default: clm.

.PARAMETER FlowFolder
    Path to the flow folder (definition.json + manifest.json).

.EXAMPLE
    .\Deploy-CLMDiscoveryFlow.ps1 -EnvironmentUrl https://contoso.crm6.dynamics.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$SolutionUniqueName = 'clmDiscoveryFlow',
    [string]$SolutionDisplayName = 'CLM Discovery Flow',
    [string]$PublisherUniqueName = 'clmPlatformOps',
    [string]$PublisherDisplayName = 'CLM Platform Ops',
    [string]$PublisherPrefix     = 'clm',
    [int]   $PublisherOptionSetPrefix = 70000,
    [string]$FlowFolder = (Join-Path $PSScriptRoot 'flows\Discovery-CLMCredentials'),
    [string]$OutputFolder = (Join-Path $PSScriptRoot 'out\flow-solution')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# UTF-8 without BOM (pac solution pack rejects BOMs in some XML files)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-TextFile {
    param([string]$Path, [string]$Content)
    $full = [System.IO.Path]::GetFullPath($Path)
    [System.IO.File]::WriteAllText($full, $Content, $script:utf8NoBom)
}

function Ensure-Pac {
    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if ($pac) { return $pac.Source }
    Write-Host "Installing Power Platform CLI (pac) via dotnet tool..." -ForegroundColor Yellow
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw ".NET SDK 6+ is required to install pac. https://dotnet.microsoft.com/download"
    }
    dotnet tool install --global Microsoft.PowerApps.CLI.Tool | Out-Null
    $env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"
    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pac) { throw "pac install failed — open a new shell or add %USERPROFILE%\.dotnet\tools to PATH." }
    return $pac.Source
}

$pacExe = Ensure-Pac

# --------------------------------------------------------------------------
# 1. Load definition + manifest
# --------------------------------------------------------------------------
$definitionPath = Join-Path $FlowFolder 'definition.json'
$manifestPath   = Join-Path $FlowFolder 'manifest.json'
if (-not (Test-Path $definitionPath)) { throw "Missing $definitionPath" }
if (-not (Test-Path $manifestPath))   { throw "Missing $manifestPath" }

$definition = Get-Content $definitionPath -Raw | ConvertFrom-Json
$manifest   = Get-Content $manifestPath   -Raw | ConvertFrom-Json

# --------------------------------------------------------------------------
# 2. Lay out an unpacked solution
# --------------------------------------------------------------------------
$srcRoot = Join-Path $OutputFolder 'src'
if (Test-Path $srcRoot) { Remove-Item $srcRoot -Recurse -Force }
New-Item -ItemType Directory -Path $srcRoot               -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $srcRoot 'Workflows') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $srcRoot 'Other')     -Force | Out-Null

# pac solution unpack emits the workflow filename with UPPERCASE GUID, but
# Solution.xml RootComponent/id and the .json.data.xml WorkflowId attribute
# use the LOWERCASE braced form. Match that exactly — Dataverse's solution
# importer compares the RootComponent id against the WorkflowId attribute as
# strings and the wrong casing makes it report "component {GUID} of type 29
# is not declared in the solution file as a root component".
$flowGuidUpper  = [Guid]::NewGuid().ToString().ToUpperInvariant()
$flowGuidLower  = $flowGuidUpper.ToLowerInvariant()
$flowName       = 'Discovery-CLMCredentials'
$workflowFile   = Join-Path $srcRoot ("Workflows\$flowName-$flowGuidUpper.json")
$workflowMeta   = Join-Path $srcRoot ("Workflows\$flowName-$flowGuidUpper.json.data.xml")

# Workflow JSON wrapper expected by solution pack for ModernFlow.
# IMPORTANT:
#  - The KEY in connectionReferences MUST match the `connectionName` used by each
#    action inside the definition (e.g. "shared_commondataserviceforapps"),
#    otherwise the workflow import throws NullReferenceException.
#  - connectionReferenceLogicalName must be the *already-prefixed* logical name
#    from manifest.json (e.g. "clm_dataverse"); do NOT prepend the prefix again.
$connRefsMap = [ordered]@{}
foreach ($cr in $manifest.connectionReferences) {
    $connRefsMap[$cr.apiName] = [ordered]@{
        api           = [ordered]@{ name = $cr.apiName }
        connection    = [ordered]@{ connectionReferenceLogicalName = $cr.logicalName }
        runtimeSource = 'embedded'
    }
}

# Build the <connectionreferences> XML fragment that ships the CRs as solution
# components, and the matching RootComponent entries (type 10044). Without these
# the workflow import fails with NullReferenceException because Dataverse cannot
# resolve the connectionReferenceLogicalName values inside the workflow JSON.
$crEntriesXml      = New-Object System.Text.StringBuilder
$crRootCompXml     = New-Object System.Text.StringBuilder
# Connection references must be declared in Customizations.xml only — the
# Dataverse importer rejects RootComponent type=10044 with "Invalid component
# type provided 10044". The <connectionreferences> block alone is enough to
# create them as solution components.
foreach ($cr in $manifest.connectionReferences) {
    [void]$crEntriesXml.AppendLine(@"
    <connectionreference connectionreferencelogicalname="$($cr.logicalName)">
      <connectionreferencedisplayname>$($cr.displayName)</connectionreferencedisplayname>
      <connectorid>/providers/Microsoft.PowerApps/apis/$($cr.apiName)</connectorid>
      <description>$($cr.description)</description>
      <iscustomizable>1</iscustomizable>
      <statecode>0</statecode>
      <statuscode>1</statuscode>
    </connectionreference>
"@)
}
$connectionReferencesBlock = "  <connectionreferences>`r`n$($crEntriesXml.ToString())  </connectionreferences>"

$wfJson = [ordered]@{
    properties = [ordered]@{
        connectionReferences = $connRefsMap
        definition           = $definition
        templateName         = $null
    }
    schemaVersion = '1.0.0.0'
}
# Ensure the workflow definition exposes the $authentication SecureObject
# parameter that pac/Power Automate emits for every modern flow. Without it
# the flow imports as a malformed definition and Dataverse throws NRE.
if (-not $wfJson.properties.definition.PSObject.Properties['parameters']) {
    $wfJson.properties.definition | Add-Member -NotePropertyName parameters -NotePropertyValue ([ordered]@{}) -Force
}
$paramsObj = $wfJson.properties.definition.parameters
if (-not $paramsObj.PSObject.Properties['$authentication']) {
    $paramsObj | Add-Member -NotePropertyName '$authentication' -NotePropertyValue ([ordered]@{
        defaultValue = @{}
        type         = 'SecureObject'
    }) -Force
}
# Any modern flow with connector actions also requires $connections; without
# it activation reports: "The provided flow definition with a recurrent
# trigger is missing the required parameter '$connections'."
if (-not $paramsObj.PSObject.Properties['$connections']) {
    $paramsObj | Add-Member -NotePropertyName '$connections' -NotePropertyValue ([ordered]@{
        defaultValue = @{}
        type         = 'Object'
    }) -Force
}
Write-TextFile -Path $workflowFile -Content ($wfJson | ConvertTo-Json -Depth 50)

# Workflow metadata sidecar — must mirror the shape pac solution unpack
# produces for a saved-but-off modern flow:
#   StateCode=1, StatusCode=2  -> Off / Saved (not turned on at import time)
#   Category=5, Type=1, Scope=4, ModernFlowType=0  -> modern cloud flow
#   LocalizedName must match the flow display name.
$workflowXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Workflow WorkflowId="{$flowGuidLower}" Name="$flowName" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <JsonFileName>/Workflows/$flowName-$flowGuidUpper.json</JsonFileName>
  <Type>1</Type>
  <Subprocess>0</Subprocess>
  <Category>5</Category>
  <Mode>0</Mode>
  <Scope>4</Scope>
  <OnDemand>0</OnDemand>
  <TriggerOnCreate>0</TriggerOnCreate>
  <TriggerOnDelete>0</TriggerOnDelete>
  <AsyncAutodelete>0</AsyncAutodelete>
  <SyncWorkflowLogOnFailure>0</SyncWorkflowLogOnFailure>
  <StateCode>1</StateCode>
  <StatusCode>2</StatusCode>
  <RunAs>1</RunAs>
  <IsTransacted>1</IsTransacted>
  <IntroducedVersion>1.0.0.0</IntroducedVersion>
  <IsCustomizable>1</IsCustomizable>
  <BusinessProcessType>0</BusinessProcessType>
  <IsCustomProcessingStepAllowedForOtherPublishers>1</IsCustomProcessingStepAllowedForOtherPublishers>
  <ModernFlowType>0</ModernFlowType>
  <PrimaryEntity>none</PrimaryEntity>
  <LocalizedNames>
    <LocalizedName languagecode="1033" description="$flowName" />
  </LocalizedNames>
</Workflow>
"@
Write-TextFile -Path $workflowMeta -Content $workflowXml

# --------------------------------------------------------------------------
# 3. solution.xml + customizations.xml + Content Types
# --------------------------------------------------------------------------
$solutionXml = @"
<?xml version="1.0" encoding="utf-8"?>
<ImportExportXml version="9.2.0.0" SolutionPackageVersion="9.2" languagecode="1033" generatedBy="CrmLive" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <SolutionManifest>
    <UniqueName>$SolutionUniqueName</UniqueName>
    <LocalizedNames>
      <LocalizedName description="$SolutionDisplayName" languagecode="1033" />
    </LocalizedNames>
    <Descriptions>
      <Description description="CLM credential discovery flow" languagecode="1033" />
    </Descriptions>
    <Version>1.0.0.0</Version>
    <Managed>0</Managed>
    <Publisher>
      <UniqueName>$PublisherUniqueName</UniqueName>
      <LocalizedNames>
        <LocalizedName description="$PublisherDisplayName" languagecode="1033" />
      </LocalizedNames>
      <Descriptions>
        <Description description="$PublisherDisplayName" languagecode="1033" />
      </Descriptions>
      <EMailAddress xsi:nil="true" />
      <SupportingWebsiteUrl xsi:nil="true" />
      <CustomizationPrefix>$PublisherPrefix</CustomizationPrefix>
      <CustomizationOptionValuePrefix>$PublisherOptionSetPrefix</CustomizationOptionValuePrefix>
      <Addresses />
    </Publisher>
    <RootComponents>
      <RootComponent type="29" id="{$flowGuidLower}" behavior="0" />
    </RootComponents>
    <MissingDependencies />
  </SolutionManifest>
</ImportExportXml>
"@
Write-TextFile -Path (Join-Path $srcRoot 'Other\Solution.xml') -Content $solutionXml

$customizationsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<ImportExportXml version="9.2.0.0" SolutionPackageVersion="9.2" languagecode="1033" generatedBy="CrmLive" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Entities />
  <Roles />
  <Workflows />
$connectionReferencesBlock
  <FieldSecurityProfiles />
  <Templates />
  <EntityMaps />
  <EntityRelationships />
  <OrganizationSettings />
  <optionsets />
  <SolutionPluginAssemblies />
  <Languages>
    <Language>1033</Language>
  </Languages>
</ImportExportXml>
"@
Write-TextFile -Path (Join-Path $srcRoot 'Other\Customizations.xml') -Content $customizationsXml

$contentTypesXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml"  ContentType="application/octet-stream" />
  <Default Extension="json" ContentType="application/octet-stream" />
</Types>
'@
Write-TextFile -Path (Join-Path $srcRoot '[Content_Types].xml') -Content $contentTypesXml

# --------------------------------------------------------------------------
# 4. Pack + import
# --------------------------------------------------------------------------
$zipPath = Join-Path $OutputFolder 'clm-discovery-flow.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Host "Packing solution..." -ForegroundColor Cyan
& $pacExe solution pack --zipfile $zipPath --folder $srcRoot --packagetype Unmanaged
if ($LASTEXITCODE -ne 0) { throw "pac solution pack failed." }

Write-Host "Authenticating to $EnvironmentUrl ..." -ForegroundColor Cyan
# & $pacExe auth create --url $EnvironmentUrl | Out-Null
if ($LASTEXITCODE -ne 0) { throw "pac auth create failed." }

Write-Host "Importing solution... COMMENTED - to Manual Import" -ForegroundColor Cyan
Write-Host "Import solution manually from the $zipPath ..." -ForegroundColor Red

# & $pacExe solution import --path $zipPath --activate-plugins --publish-changes
if ($LASTEXITCODE -ne 0) { throw "pac solution import failed." }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Discovery flow imported" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open make.powerautomate.com -> Solutions -> '$SolutionDisplayName' -> Discovery-CLMCredentials."
Write-Host "  2. Authorize the three connection references (Graph, ARM, Dataverse)."
Write-Host "  3. Turn the flow ON, then Test -> Manually -> Run flow."
Write-Host "  4. Verify clm_credentials and clm_renewalevents in the model-driven app."
