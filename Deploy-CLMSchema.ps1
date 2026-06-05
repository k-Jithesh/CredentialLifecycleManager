<#
.SYNOPSIS
    Deploys the Credential Lifecycle Manager (CLM) Dataverse schema using the Web API.

.DESCRIPTION
    Creates the publisher, solution, tables, columns, global option sets, relationships,
    alternate keys and security roles defined in solution_manifest.json. Idempotent —
    safe to re-run.

.PARAMETER EnvironmentUrl
    e.g. https://contoso.crm6.dynamics.com

.PARAMETER ManifestPath
    Path to solution_manifest.json (defaults to alongside this script).

.EXAMPLE
    pwsh ./Deploy-CLMSchema.ps1 -EnvironmentUrl https://contoso.crm6.dynamics.com

.NOTES
    Requires PowerShell 7+ and the Microsoft.PowerApps.Administration.PowerShell module
    OR an interactive AAD login via Az.Accounts. Uses delegated user token with
    Dataverse Web API (requires user to be System Customizer or System Administrator).
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $ManifestPath = (Join-Path $PSScriptRoot 'solution_manifest.json'),

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [string] $TenantId,

    [Parameter(ParameterSetName = 'Interactive')]
    [string] $AccountId,

    [Parameter(ParameterSetName = 'Interactive')]
    [switch] $UseDeviceCode,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [switch] $ServicePrincipal,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [string] $ClientId,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [string] $ClientSecret,

    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [string] $CertificateThumbprint
)

$ErrorActionPreference = 'Stop'

# --- Acquire token via Az.Accounts ---
if (-not (Get-Module -ListAvailable Az.Accounts)) {
    Write-Host 'Installing Az.Accounts...' -ForegroundColor Yellow
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Accounts

$resource = $EnvironmentUrl.TrimEnd('/')
$isSp     = $ServicePrincipal.IsPresent

# Reuse an existing context only if it already matches the requested tenant
# AND the auth mode (interactive vs SP). Otherwise re-auth.
$ctx       = Get-AzContext
$needLogin = $true
if ($ctx -and -not $isSp) {
    if (-not $TenantId -or $ctx.Tenant.Id -eq $TenantId) {
        $needLogin = $false
    }
}

if ($needLogin) {
    $connectArgs = @{ ErrorAction = 'Stop'; TenantId = $TenantId }

    if ($isSp) {
        $connectArgs.ServicePrincipal = $true
        $connectArgs.ApplicationId    = $ClientId

        if ($PSCmdlet.ParameterSetName -eq 'ServicePrincipalCert') {
            $connectArgs.CertificateThumbprint = $CertificateThumbprint
        } else {
            $secure = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
            $connectArgs.Credential = [System.Management.Automation.PSCredential]::new($ClientId, $secure)
            $connectArgs.Remove('ApplicationId') | Out-Null
        }

        Write-Host "Signing in as service principal $ClientId to tenant $TenantId..." -ForegroundColor Cyan
        Connect-AzAccount @connectArgs | Out-Null
    }
    else {
        if ($AccountId)     { $connectArgs.AccountId = $AccountId }
        if ($UseDeviceCode) { $connectArgs.UseDeviceAuthentication = $true }

        try {
            Connect-AzAccount @connectArgs | Out-Null
        } catch {
            Write-Warning "Interactive sign-in failed: $($_.Exception.Message)"
            Write-Host 'Retrying with device-code flow...' -ForegroundColor Yellow
            $connectArgs.UseDeviceAuthentication = $true
            Connect-AzAccount @connectArgs | Out-Null
        }
    }
}

# Force the token request against the target tenant explicitly — this avoids
# silently using a cached home-tenant token.
$tokenArgs = @{ ResourceUrl = $resource }
if ($TenantId) { $tokenArgs.TenantId = $TenantId }
$token = (Get-AzAccessToken @tokenArgs).Token
$headers  = @{
    Authorization      = "Bearer $token"
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    Accept             = 'application/json'
    'Content-Type'     = 'application/json; charset=utf-8'
    'MSCRM.SolutionUniqueName' = 'CredentialLifecycleManager'
}
$apiBase = "$resource/api/data/v9.2"

# --- Load manifest ---
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json -Depth 30
$prefix   = $manifest.publisher.customizationPrefix

# Dataverse error codes that mean "the thing you asked about does not exist".
# We treat these as a soft miss on GET so the script remains idempotent.
$script:NotFoundCodes = @(
    '0x80060888',  # EntityMetadata not found
    '0x80090020',  # AttributeMetadata not found
    '0x8006088a',  # OptionSet metadata not found
    '0x80060889'   # Relationship metadata not found
)

# Dataverse error codes / phrases that mean "this already exists".
# We treat these as a soft success on POST so re-runs are safe.
$script:DuplicateCodes = @(
    'duplicate', 'already exists', 'cannot be created because the name',
    '0x80045001',  # duplicate record
    '0x80060891',  # attribute exists
    '0x80060890',  # entity exists
    '0x8004f50c',  # relationship duplicate
    '0x80060835',  # alternate key already exists
    '0x80044150'   # global option set name in use
)

function Invoke-Dv {
    param(
        [Parameter(Mandatory)] $Method,
        [Parameter(Mandatory)] $Path,
        $Body,
        [switch] $AllowNotFound,
        [switch] $AllowDuplicate
    )
    $uri = if ($Path -match '^https?://') { $Path } else { "$apiBase/$Path" }
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers }
    if ($Body) { $params.Body = ([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress))) }
    try {
        Invoke-RestMethod @params
    } catch {
        $msg    = $_.ErrorDetails.Message
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }

        # --- "Not found" handling — primarily for idempotent GET existence checks ---
        $isNotFound = ($status -eq 404) -or
                      ($msg -and ($script:NotFoundCodes | Where-Object { $msg -match $_ })) -or
                      ($msg -match 'does not exist|Could not find|was not found')
        if ($isNotFound -and ($Method -eq 'GET' -or $AllowNotFound)) {
            return $null
        }

        # --- "Already exists" handling — for idempotent POST/PATCH creates ---
        $isDuplicate = $false
        if ($msg) {
            foreach ($pat in $script:DuplicateCodes) {
                if ($msg -match [regex]::Escape($pat)) { $isDuplicate = $true; break }
            }
        }
        if ($isDuplicate -and ($Method -in @('POST','PATCH','PUT') -or $AllowDuplicate)) {
            Write-Host "  (exists) $Path" -ForegroundColor DarkGray
            return $null
        }

        throw "Dataverse $Method $Path failed [$status]: $msg"
    }
}

function New-Publisher {
    Write-Host "Ensuring publisher $($manifest.publisher.uniqueName)..." -ForegroundColor Cyan
    $existing = Invoke-Dv GET "publishers?`$filter=uniquename eq '$($manifest.publisher.uniqueName)'&`$select=publisherid"
    if ($existing.value.Count -gt 0) { return $existing.value[0].publisherid }
    $body = @{
        uniquename                   = $manifest.publisher.uniqueName
        friendlyname                 = $manifest.publisher.friendlyName
        description                  = $manifest.publisher.description
        customizationprefix          = $manifest.publisher.customizationPrefix
        customizationoptionvalueprefix = [int]$manifest.publisher.optionValuePrefix
    }
    $r = Invoke-Dv POST 'publishers' $body
    Write-Host "  created publisher" -ForegroundColor Green
}

function New-Solution {
    Write-Host "Ensuring solution $($manifest.solution.uniqueName)..." -ForegroundColor Cyan
    $existing = Invoke-Dv GET "solutions?`$filter=uniquename eq '$($manifest.solution.uniqueName)'&`$select=solutionid"
    if ($existing.value.Count -gt 0) { return }
    $pub = (Invoke-Dv GET "publishers?`$filter=uniquename eq '$($manifest.publisher.uniqueName)'&`$select=publisherid").value[0]
    $body = @{
        uniquename               = $manifest.solution.uniqueName
        friendlyname             = $manifest.solution.friendlyName
        description              = $manifest.solution.description
        version                  = $manifest.solution.version
        'publisherid@odata.bind' = "/publishers($($pub.publisherid))"
    }
    Invoke-Dv POST 'solutions' $body | Out-Null
    Write-Host "  created solution" -ForegroundColor Green
}

function New-GlobalOptionSet($os) {
    Write-Host "Option set: $($os.schemaName)..." -ForegroundColor Cyan
    $exists = Invoke-Dv GET "GlobalOptionSetDefinitions(Name='$($os.schemaName)')?`$select=Name"
    if ($exists) {
        Write-Host "  exists - skipping" -ForegroundColor DarkGray
        return
    }
    $body = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.OptionSetMetadata'
        Name          = $os.schemaName
        DisplayName   = @{ LocalizedLabels = @(@{ Label = $os.displayName; LanguageCode = 1033 }) }
        Description   = @{ LocalizedLabels = @(@{ Label = $os.description; LanguageCode = 1033 }) }
        IsGlobal      = $true
        OptionSetType = 'Picklist'
        Options       = @($os.options | ForEach-Object {
            @{
                Value       = $_.value
                Label       = @{ LocalizedLabels = @(@{ Label = $_.label; LanguageCode = 1033 }) }
                Description = @{ LocalizedLabels = @(@{ Label = $_.description; LanguageCode = 1033 }) }
            }
        })
    }
    Invoke-Dv POST 'GlobalOptionSetDefinitions' $body | Out-Null
}

$script:OptionSetIdCache = @{}

function Get-GlobalOptionSetId($name) {
    if ($script:OptionSetIdCache.ContainsKey($name)) { return $script:OptionSetIdCache[$name] }
    $r = Invoke-Dv GET "GlobalOptionSetDefinitions(Name='$name')?`$select=MetadataId"
    if (-not $r -or -not $r.MetadataId) {
        throw "Global option set '$name' not found in Dataverse. Ensure it was created before any column references it."
    }
    $script:OptionSetIdCache[$name] = $r.MetadataId
    return $r.MetadataId
}

function Build-Attribute($col) {
    $base = @{
        SchemaName  = $col.schemaName
        DisplayName = @{ LocalizedLabels = @(@{ Label = $col.displayName; LanguageCode = 1033 }) }
        Description = @{ LocalizedLabels = @(@{ Label = $col.description; LanguageCode = 1033 }) }
        RequiredLevel = @{ Value = $col.requiredLevel }
    }
    switch ($col.dataType) {
        'String' {
            $base['@odata.type']  = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
            $base.AttributeType   = 'String'
            $base.MaxLength       = $col.maxLength
            $base.FormatName      = @{ Value = ($col.format ?? 'Text') }
        }
        'Memo' {
            $base['@odata.type'] = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'
            $base.AttributeType  = 'Memo'
            $base.MaxLength      = $col.maxLength
            $base.Format         = 'TextArea'
        }
        'DateTime' {
            $base['@odata.type'] = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'
            $base.AttributeType  = 'DateTime'
            $base.Format         = 'DateAndTime'
            $base.DateTimeBehavior = @{ Value = 'UserLocal' }
        }
        'Integer' {
            $base['@odata.type'] = 'Microsoft.Dynamics.CRM.IntegerAttributeMetadata'
            $base.AttributeType  = 'Integer'
            $base.MinValue       = -2147483648
            $base.MaxValue       = 2147483647
            $base.Format         = 'None'
        }
        'Boolean' {
            $base['@odata.type'] = 'Microsoft.Dynamics.CRM.BooleanAttributeMetadata'
            $base.AttributeType  = 'Boolean'
            $base.OptionSet      = @{
                TrueOption  = @{ Value = 1; Label = @{ LocalizedLabels = @(@{ Label = 'Yes'; LanguageCode = 1033 }) } }
                FalseOption = @{ Value = 0; Label = @{ LocalizedLabels = @(@{ Label = 'No';  LanguageCode = 1033 }) } }
            }
            $base.DefaultValue   = $false
        }
        'Url' {
            $base['@odata.type'] = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
            $base.AttributeType  = 'String'
            $base.MaxLength      = $col.maxLength
            $base.FormatName     = @{ Value = 'Url' }
        }
        'Choice' {
            $base['@odata.type'] = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'
            $base.AttributeType  = 'Picklist'
            $osId = Get-GlobalOptionSetId $col.optionSet
            $base['GlobalOptionSet@odata.bind'] = "/GlobalOptionSetDefinitions($osId)"
        }
        'MultiChoice' {
            $base['@odata.type'] = 'Microsoft.Dynamics.CRM.MultiSelectPicklistAttributeMetadata'
            $base.AttributeType  = 'Virtual'
            $osId = Get-GlobalOptionSetId $col.optionSet
            $base['GlobalOptionSet@odata.bind'] = "/GlobalOptionSetDefinitions($osId)"
        }
    }
    return $base
}

function New-Table($t) {
    Write-Host "Table $($t.schemaName)..." -ForegroundColor Cyan
    $exists = Invoke-Dv GET "EntityDefinitions(LogicalName='$($t.schemaName.ToLower())')?`$select=LogicalName"
    if ($exists) {
        Write-Host "  exists - skipping create" -ForegroundColor DarkGray
    } else {
        $primary = $t.columns | Where-Object { $_.isPrimary } | Select-Object -First 1
        $primaryAttr = Build-Attribute $primary
        $primaryAttr.IsPrimaryName = $true

        $body = @{
            '@odata.type'        = 'Microsoft.Dynamics.CRM.EntityMetadata'
            SchemaName           = $t.schemaName
            LogicalName          = $t.schemaName.ToLower()
            DisplayName          = @{ LocalizedLabels = @(@{ Label = $t.displayName;           LanguageCode = 1033 }) }
            DisplayCollectionName= @{ LocalizedLabels = @(@{ Label = $t.displayCollectionName; LanguageCode = 1033 }) }
            Description          = @{ LocalizedLabels = @(@{ Label = $t.description;           LanguageCode = 1033 }) }
            OwnershipType        = $t.ownershipType
            HasActivities        = $false
            HasNotes             = $false
            IsActivity           = $false
            IsAuditEnabled       = @{ Value = $t.enableAuditing }
            IsValidForQueue      = @{ Value = $false }
            ChangeTrackingEnabled= $t.enableChangeTracking
            Attributes           = @($primaryAttr)
        }
        Invoke-Dv POST 'EntityDefinitions?MSCRM.SolutionUniqueName=CredentialLifecycleManager' $body | Out-Null
        Write-Host "  created" -ForegroundColor Green
    }

    foreach ($col in $t.columns | Where-Object { -not $_.isPrimary }) {
        $tableLn = $t.schemaName.ToLower()
        $colLn   = $col.schemaName.ToLower()
        $attrExists = Invoke-Dv GET "EntityDefinitions(LogicalName='$tableLn')/Attributes(LogicalName='$colLn')?`$select=LogicalName"
        if ($attrExists) {
            Write-Host "  = $($col.schemaName) [$($col.dataType)] (exists)" -ForegroundColor DarkGray
            continue
        }
        $attr = Build-Attribute $col
        Write-Host "  + $($col.schemaName) [$($col.dataType)]" -ForegroundColor DarkCyan
        Invoke-Dv POST "EntityDefinitions(LogicalName='$tableLn')/Attributes?MSCRM.SolutionUniqueName=CredentialLifecycleManager" $attr | Out-Null
    }
}

function New-Relationship($r) {
    Write-Host "Relationship $($r.schemaName)..." -ForegroundColor Cyan
    $relExists = Invoke-Dv GET "RelationshipDefinitions(SchemaName='$($r.schemaName)')?`$select=SchemaName"
    if ($relExists) {
        Write-Host "  exists - skipping" -ForegroundColor DarkGray
        return
    }
    $body = @{
        '@odata.type'           = 'Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata'
        SchemaName              = $r.schemaName
        ReferencedEntity        = $r.referencedEntity.ToLower()
        ReferencingEntity       = $r.referencingEntity.ToLower()
        ReferencedAttribute     = ($r.referencedAttribute ?? "$($r.referencedEntity.ToLower())id")
        Lookup = @{
            '@odata.type'   = 'Microsoft.Dynamics.CRM.LookupAttributeMetadata'
            SchemaName      = $r.referencingAttribute
            DisplayName     = @{ LocalizedLabels = @(@{ Label = $r.displayName; LanguageCode = 1033 }) }
            RequiredLevel   = @{ Value = ($r.requiredLevel ?? 'None') }
        }
        CascadeConfiguration = @{
            Assign   = ($r.cascade ?? 'NoCascade')
            Delete   = ($r.cascadeDelete ?? 'Restrict')
            Reparent = 'NoCascade'
            Share    = 'NoCascade'
            Unshare  = 'NoCascade'
            Merge    = 'NoCascade'
        }
    }
    Invoke-Dv POST 'RelationshipDefinitions?MSCRM.SolutionUniqueName=CredentialLifecycleManager' $body | Out-Null
}

function New-AlternateKey($k) {
    Write-Host "Alternate key $($k.keyName) on $($k.entity)..." -ForegroundColor Cyan
    $entLn = $k.entity.ToLower()
    $keyExists = Invoke-Dv GET "EntityDefinitions(LogicalName='$entLn')/Keys(SchemaName='$($k.keyName)')?`$select=SchemaName"
    if ($keyExists) {
        Write-Host "  exists - skipping" -ForegroundColor DarkGray
        return
    }
    $body = @{
        '@odata.type'   = 'Microsoft.Dynamics.CRM.EntityKeyMetadata'
        SchemaName      = $k.keyName
        DisplayName     = @{ LocalizedLabels = @(@{ Label = $k.keyName; LanguageCode = 1033 }) }
        KeyAttributes   = @($k.attributes)
    }
    Invoke-Dv POST "EntityDefinitions(LogicalName='$entLn')/Keys?MSCRM.SolutionUniqueName=CredentialLifecycleManager" $body | Out-Null
}

# --- Execute ---
New-Publisher
New-Solution

foreach ($os in $manifest.optionSets) { New-GlobalOptionSet $os }
foreach ($t  in $manifest.tables)     { New-Table $t }
foreach ($r  in $manifest.relationships) { New-Relationship $r }
foreach ($k  in $manifest.alternateKeys) { New-AlternateKey $k }

Write-Host "`nDONE. Solution 'CredentialLifecycleManager' provisioned." -ForegroundColor Green
Write-Host "Next: assign CLM security roles in the maker portal (see schema_csv/10_security_roles.csv)."
