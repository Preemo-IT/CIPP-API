function Get-NormalizedError {
    [CmdletBinding()]
    param (
        [string]$message
    )
    switch -Wildcard ($message) {
        'Request not applicable to target tenant.' { 'Required license not available for this tenant' }
        "Neither tenant is B2C or tenant doesn't have premium license" { 'This feature requires a P1 license or higher' }
        'Response status code does not indicate success: 400 (Bad Request).' { 'Error 400 occured. There is an issue with the token configuration for this tenant. Please perform an access check' }
        '*Microsoft.Skype.Sync.Pstn.Tnm.Common.Http.HttpResponseException*' { 'Could not connect to Teams Admin center - Tenant might be missing a Teams license' }
        '*Provide valid credential.*' { 'Error 400: There is an issue with your Exchange Token configuration. Please perform an access check for this tenant' }
        Default { $message }
    }
}

function Get-GraphToken($tenantid, $scope, $AsApp, $AppID, $refreshToken, $ReturnRefresh) {
    if (!$scope) { $scope = 'https://graph.microsoft.com//.default' }

    $AuthBody = @{
        client_id     = $ENV:ApplicationId
        client_secret = $ENV:ApplicationSecret
        scope         = $Scope
        refresh_token = $ENV:RefreshToken
        grant_type    = 'refresh_token'
                    
    }
    if ($asApp -eq $true) {
        $AuthBody = @{
            client_id     = $ENV:ApplicationId
            client_secret = $ENV:ApplicationSecret
            scope         = $Scope
            grant_type    = 'client_credentials'
        }
    }

    if ($null -ne $AppID -and $null -ne $refreshToken) {
        $AuthBody = @{
            client_id     = $appid
            refresh_token = $RefreshToken
            scope         = $Scope
            grant_type    = 'refresh_token'
        }
    }

    if (!$tenantid) { $tenantid = $env:tenantid }
    $AccessToken = (Invoke-RestMethod -Method post -Uri "https://login.microsoftonline.com/$($tenantid)/oauth2/v2.0/token" -Body $Authbody -ErrorAction Stop)
    if ($ReturnRefresh) { $header = $AccessToken } else { $header = @{ Authorization = "Bearer $($AccessToken.access_token)" } }

    return $header
}

function Log-Request ($message, $tenant, $API, $user, $sev) {
    $username = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($user)) | ConvertFrom-Json).userDetails
    New-Item -Path 'Logs' -ItemType Directory -ErrorAction SilentlyContinue
    $date = (Get-Date).ToString('s')
    $LogMutex = New-Object System.Threading.Mutex($false, 'LogMutex')
    if (!$username) { $username = 'CIPP' }
    if (!$tenant) { $tenant = 'None' }
    if ($sev -eq 'Debug' -and $env:DebugMode -ne 'true') { 
        Write-Information 'Not writing to log file - Debug mode is not enabled.'
        return
    }
    $CleanMessage = [string]::join(' ', ($message.Split("`n")))
    $logdata = "$($date)|$($tenant)|$($API)|$($CleanMessage)|$($username)|$($sev)"
    if ($LogMutex.WaitOne(1000)) {
        $logdata | Out-File -Append -FilePath "Logs\$((Get-Date).ToString('ddMMyyyy')).log" -Force
    }
    $LogMutex.ReleaseMutex()
}

function New-GraphGetRequest ($uri, $tenantid, $scope, $AsApp, $noPagination) {

    if ($scope -eq 'ExchangeOnline') { 
        $Headers = Get-GraphToken -AppID 'a0c73c16-a7e3-4564-9a95-2bdf47383716' -RefreshToken $ENV:ExchangeRefreshToken -Scope 'https://outlook.office365.com/.default' -Tenantid $tenantid
    }
    else {
        $headers = Get-GraphToken -tenantid $tenantid -scope $scope -AsApp $asapp
    }
    Write-Verbose "Using $($uri) as url"
    $nextURL = $uri
    
    if ((Get-AuthorisedRequest -Uri $uri -TenantID $tenantid)) {
        $ReturnedData = do {
            try {
                $Data = (Invoke-RestMethod -Uri $nextURL -Method GET -Headers $headers -ContentType 'application/json; charset=utf-8')
                if ($data.value) { $data.value } else { ($Data) }
                if ($noPagination) { $nextURL = $null } else { $nextURL = $data.'@odata.nextLink' }                
            }
            catch {
                $Message = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message
                if ($Message -eq $null) { $Message = $($_.Exception.Message) }
                throw $Message
            }
        } until ($null -eq $NextURL)
        return $ReturnedData   
    }
    else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope' 
    }
}       

function New-GraphPOSTRequest ($uri, $tenantid, $body, $type, $scope, $AsApp) {

    $headers = Get-GraphToken -tenantid $tenantid -scope $scope -AsApp $asapp
    Write-Verbose "Using $($uri) as url"
    if (!$type) {
        $type = 'POST'
    }
   
    if ((Get-AuthorisedRequest -Uri $uri -TenantID $tenantid)) {
        try {
            $ReturnedData = (Invoke-RestMethod -Uri $($uri) -Method $TYPE -Body $body -Headers $headers -ContentType 'application/json; charset=utf-8')
        }
        catch {
            $Message = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message
            if ($Message -eq $null) { $Message = $($_.Exception.Message) }
            throw $Message
        }
        return $ReturnedData 
    }
    else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope' 
    }
}

function convert-skuname($skuname, $skuID) {
    $ConvertTable = Import-Csv Conversiontable.csv
    if ($skuname) { $ReturnedName = ($ConvertTable | Where-Object { $_.String_Id -eq $skuname } | Select-Object -Last 1).'Product_Display_Name' }
    if ($skuID) { $ReturnedName = ($ConvertTable | Where-Object { $_.guid -eq $skuid } | Select-Object -Last 1).'Product_Display_Name' }
    if ($ReturnedName) { return $ReturnedName } else { return $skuname, $skuID }
}

function Get-ClassicAPIToken($tenantID, $Resource) {
    $uri = "https://login.microsoftonline.com/$($TenantID)/oauth2/token"
    $body = "resource=$Resource&grant_type=refresh_token&refresh_token=$($ENV:ExchangeRefreshToken)"
    try {
        $token = Invoke-RestMethod $uri -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction SilentlyContinue -Method post
        return $token
    }
    catch {
        Write-Error "Failed to obtain Classic API Token for $Tenant - $_"        
    }
}

function New-TeamsAPIGetRequest($Uri, $tenantID, $Method = 'GET', $Resource = '48ac35b8-9aa8-4d74-927d-1f4a14a0b239', $ContentType = 'application/json') {
    $token = Get-ClassicAPIToken -Tenant $tenantid -Resource $Resource

    $NextURL = $Uri
    
    if ((Get-AuthorisedRequest -Uri $uri -TenantID $tenantid)) {
        $ReturnedData = do {
            try {
                $Data = Invoke-RestMethod -ContentType "$ContentType;charset=UTF-8" -Uri $NextURL -Method $Method -Headers @{
                    Authorization            = "Bearer $($token.access_token)";
                    'x-ms-client-request-id' = [guid]::NewGuid().ToString();
                    'x-ms-client-session-id' = [guid]::NewGuid().ToString()
                    'x-ms-correlation-id'    = [guid]::NewGuid()
                    'X-Requested-With'       = 'XMLHttpRequest' 
                    'x-ms-tnm-applicationid' = '045268c0-445e-4ac1-9157-d58f67b167d9'

                } 
                $Data
                if ($noPagination) { $nextURL = $null } else { $nextURL = $data.NextLink }            
            }
            catch {
                throw "Failed to make Classic Get Request $_"
            }
        } until ($null -eq $NextURL)
        return $ReturnedData
    }
    else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope' 
    }
}

function New-ClassicAPIGetRequest($TenantID, $Uri, $Method = 'GET', $Resource = 'https://admin.microsoft.com', $ContentType = 'application/json') {
    $token = Get-ClassicAPIToken -Tenant $tenantID -Resource $Resource

    $NextURL = $Uri
    
    if ((Get-AuthorisedRequest -Uri $uri -TenantID $tenantid)) {
        $ReturnedData = do {
            try {
                $Data = Invoke-RestMethod -ContentType "$ContentType;charset=UTF-8" -Uri $NextURL -Method $Method -Headers @{
                    Authorization            = "Bearer $($token.access_token)";
                    'x-ms-client-request-id' = [guid]::NewGuid().ToString();
                    'x-ms-client-session-id' = [guid]::NewGuid().ToString()
                    'x-ms-correlation-id'    = [guid]::NewGuid()
                    'X-Requested-With'       = 'XMLHttpRequest' 
                } 
                $Data
                if ($noPagination) { $nextURL = $null } else { $nextURL = $data.NextLink }            
            }
            catch {
                throw "Failed to make Classic Get Request $_"
            }
        } until ($null -eq $NextURL)
        return $ReturnedData
    }
    else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope' 
    }
}

function New-ClassicAPIPostRequest($TenantID, $Uri, $Method = 'POST', $Resource = 'https://admin.microsoft.com', $Body) {

    $token = Get-ClassicAPIToken -Tenant $tenantID -Resource $Resource

    if ((Get-AuthorisedRequest -Uri $uri -TenantID $tenantid)) {
        try {
            $ReturnedData = Invoke-RestMethod -ContentType 'application/json;charset=UTF-8' -Uri $Uri -Method $Method -Body $Body -Headers @{
                Authorization            = "Bearer $($token.access_token)";
                'x-ms-client-request-id' = [guid]::NewGuid().ToString();
                'x-ms-client-session-id' = [guid]::NewGuid().ToString()
                'x-ms-correlation-id'    = [guid]::NewGuid()
                'X-Requested-With'       = 'XMLHttpRequest' 
            } 
                       
        }
        catch {
            throw "Failed to make Classic Get Request $_"
        }
        return $ReturnedData
    }
    else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope' 
    }
}

function Get-AuthorisedRequest($TenantID, $Uri) {
    if ($uri -like 'https://graph.microsoft.com/beta/contracts*' -or $uri -like '*/customers/*' -or $uri -eq 'https://graph.microsoft.com/v1.0/me/sendMail' -or $uri -like 'https://graph.microsoft.com/beta/tenantRelationships/managedTenants*') {
        return $true
    }
    if ($TenantID -in (Get-Tenants).defaultdomainname) {
        return $true
    }
    else {
        return $false
    }

}

function Get-Tenants {
    param (
        [Parameter( ParameterSetName = 'Skip', Mandatory = $True )]
        [switch]$SkipList,
        [Parameter( ParameterSetName = 'Standard')]
        [switch]$IncludeAll
        
    )

    $cachefile = 'tenants.cache.json'
    
    if ((!$Script:SkipListCache -and !$Script:SkipListCacheEmpty) -or !$Script:IncludedTenantsCache) {
        # We create the excluded tenants file. This is not set to force so will not overwrite
        New-Item -ErrorAction SilentlyContinue -ItemType File -Path 'ExcludedTenants'
        $Script:SkipListCache = Get-Content 'ExcludedTenants' | ConvertFrom-Csv -Delimiter '|' -Header 'Name', 'User', 'Date'
        if ($null -eq $Script:SkipListCache) {
            $Script:SkipListCacheEmpty = $true
        }

        # Load or refresh the cache if older than 24 hours
        $Testfile = Get-Item $cachefile -ErrorAction SilentlyContinue | Where-Object -Property LastWriteTime -GT (Get-Date).Addhours(-24)
        if ($Testfile) {
            $Script:IncludedTenantsCache = Get-Content $cachefile -ErrorAction SilentlyContinue | ConvertFrom-Json
        }
        else {
            $Script:IncludedTenantsCache = (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/contracts?`$top=999" -tenantid $ENV:Tenantid) | Select-Object CustomerID, DefaultdomainName, DisplayName, domains | Where-Object -Property DefaultdomainName -NotIn $Script:SkipListCache.name
            if ($ENV:PartnerTenantAvailable) {
                $PartnerTenant = @([PSCustomObject]@{
                        customerId        = $env:TenantID
                        defaultDomainName = $env:TenantID
                        displayName       = '*Partner Tenant'
                        domains           = 'PartnerTenant'
                    })
                $Script:IncludedTenantsCache = $PartnerTenant + $Script:IncludedTenantsCache
            }
   
            if ($Script:IncludedTenantsCache) {
                $Script:IncludedTenantsCache | ConvertTo-Json | Out-File $cachefile
            }
        }    
    }
    if ($SkipList) {
        return $Script:SkipListCache
    }
    if ($IncludeAll) {
        return (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/contracts?`$top=999" -tenantid $ENV:Tenantid) | Select-Object CustomerID, DefaultdomainName, DisplayName, domains
    }
    
    else {
        return $Script:IncludedTenantsCache
    }
}

function Remove-CIPPCache {
    Remove-Item 'tenants.cache.json' -Force
    Get-ChildItem -Path 'Cache_BestPracticeAnalyser' -Filter *.json | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'Cache_DomainAnalyser' -Filter *.json | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'Cache_BestPracticeAnalyser\CurrentlyRunning.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'ChocoApps.Cache\CurrentlyRunning.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'Cache_DomainAnalyser\CurrentlyRunning.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'Cache_Scheduler\CurrentlyRunning.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'SecurityBaselines_All\CurrentlyRunning.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path 'Cache_Standards\CurrentlyRunning.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $Script:SkipListCache = $Null
    $Script:SkipListCacheEmpty = $Null
    $Script:IncludedTenantsCache = $Null
}

function New-ExoRequest ($tenantid, $cmdlet, $cmdParams) {
    $token = Get-ClassicAPIToken -resource 'https://outlook.office365.com' -Tenantid $tenantid 
    if ((Get-AuthorisedRequest -TenantID $tenantid)) {
        $tenant = (get-tenants | Where-Object -Property defaultDomainName -EQ $tenantid).customerid
        if ($cmdParams) {
            $Params = $cmdParams
        }
        else {
            $Params = @{}
        }
        $ExoBody = ConvertTo-Json -Depth 5 -InputObject @{
            CmdletInput = @{
                CmdletName = $cmdlet
                Parameters = $Params
            }
        } 
        $OnMicrosoft = (New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/domains?$top=999' -tenantid $tenantid | Where-Object -Property isInitial -EQ $true).id
        $Headers = @{ 
            Authorization     = "Bearer $($token.access_token)" 
            'X-AnchorMailbox' = "UPN:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$($OnMicrosoft)"

        }
        try {
            $ReturnedData = Invoke-RestMethod "https://outlook.office365.com/adminapi/beta/$($tenant)/InvokeCommand" -Method POST -Body $ExoBody -Headers $Headers -ContentType 'application/json; charset=utf-8'
        }
        catch {
            $ReportedError = ($_.ErrorDetails | ConvertFrom-Json -ErrorAction SilentlyContinue)
            $Message = if ($ReportedError.error.details.message) { $ReportedError.error.details.message } else { $ReportedError.error.innererror.internalException.message }
            if ($Message -eq $null) { $Message = $($_.Exception.Message) }
            throw $Message
        }
        return $ReturnedData.value   
    }
    else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope' 
    }
}  

function Read-JwtAccessDetails {
    <#
    .SYNOPSIS
    Parse Microsoft JWT access tokens
    
    .DESCRIPTION
    Extract JWT access token details for verification
    
    .PARAMETER Token
    Token to get details for

    #>
    [cmdletbinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    # Default token object
    $TokenDetails = [PSCustomObject]@{
        AppId             = ''
        AppName           = ''
        Audience          = ''
        AuthMethods       = ''
        IPAddress         = ''
        Name              = ''
        Scope             = ''
        TenantId          = ''
        UserPrincipalName = ''
    }
 
    if (!$Token.Contains('.') -or !$token.StartsWith('eyJ')) { return $TokenDetails }
 
    # Get token payload
    $tokenPayload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($tokenPayload.Length % 4) { 
        $tokenPayload = '{0}=' -f $tokenPayload
    }

    # Convert base64 to json to object
    $tokenByteArray = [System.Convert]::FromBase64String($tokenPayload)
    $tokenArray = [System.Text.Encoding]::ASCII.GetString($tokenByteArray)
    $TokenObj = $tokenArray | ConvertFrom-Json

    # Convert token details to human readable
    $TokenDetails.AppId = $TokenObj.appid
    $TokenDetails.AppName = $TokenObj.app_displayname
    $TokenDetails.Audience = $TokenObj.aud
    $TokenDetails.AuthMethods = $TokenObj.amr
    $TokenDetails.IPAddress = $TokenObj.ipaddr
    $TokenDetails.Name = $TokenObj.name
    $TokenDetails.Scope = $TokenObj.scp -split ' '
    $TokenDetails.TenantId = $TokenObj.tid
    $TokenDetails.UserPrincipalName = $TokenObj.upn

    return $TokenDetails
}

function Get-CIPPMSolUsers {
    [CmdletBinding()]
    param (
        [string]$tenant
    )
    $AADGraphtoken = (Get-GraphToken -scope 'https://graph.windows.net/.default')
    $tenantid = (get-tenants | Where-Object -Property DefaultDomainName -EQ $tenant).CustomerID
    $TrackingGuid = New-Guid
    $LogonPost = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing"><s:Header><a:Action s:mustUnderstand="1">http://provisioning.microsoftonline.com/IProvisioningWebService/MsolConnect</a:Action><a:MessageID>urn:uuid:$TrackingGuid</a:MessageID><a:ReplyTo><a:Address>http://www.w3.org/2005/08/addressing/anonymous</a:Address></a:ReplyTo><UserIdentityHeader xmlns="http://provisioning.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><BearerToken xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">$($AADGraphtoken['Authorization'])</BearerToken><LiveToken i:nil="true" xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService"/></UserIdentityHeader><ClientVersionHeader xmlns="http://provisioning.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ClientId xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">50afce61-c917-435b-8c6d-60aa5a8b8aa7</ClientId><Version xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">1.2.183.57</Version></ClientVersionHeader><ContractVersionHeader xmlns="http://becwebservice.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><BecVersion xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">Version47</BecVersion></ContractVersionHeader><TrackingHeader xmlns="http://becwebservice.microsoftonline.com/">$($TrackingGuid)</TrackingHeader><a:To s:mustUnderstand="1">https://provisioningapi.microsoftonline.com/provisioningwebservice.svc</a:To></s:Header><s:Body><MsolConnect xmlns="http://provisioning.microsoftonline.com/"><request xmlns:b="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><b:BecVersion>Version4</b:BecVersion><b:TenantId i:nil="true"/><b:VerifiedDomain i:nil="true"/></request></MsolConnect></s:Body></s:Envelope>
"@
    $DataBlob = (Invoke-RestMethod -Method POST -Uri 'https://provisioningapi.microsoftonline.com/provisioningwebservice.svc' -ContentType 'application/soap+xml; charset=utf-8' -Body $LogonPost).envelope.header.BecContext.DataBlob.'#text'

    $MSOLXML = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing"><s:Header><a:Action s:mustUnderstand="1">http://provisioning.microsoftonline.com/IProvisioningWebService/ListUsers</a:Action><a:MessageID>urn:uuid:$TrackingGuid</a:MessageID><a:ReplyTo><a:Address>http://www.w3.org/2005/08/addressing/anonymous</a:Address></a:ReplyTo><UserIdentityHeader xmlns="http://provisioning.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><BearerToken xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">$($AADGraphtoken['Authorization'])</BearerToken><LiveToken i:nil="true" xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService"/></UserIdentityHeader><BecContext xmlns="http://becwebservice.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><DataBlob xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">$DataBlob</DataBlob><PartitionId xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">2</PartitionId></BecContext><ClientVersionHeader xmlns="http://provisioning.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ClientId xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">50afce61-c917-435b-8c6d-60aa5a8b8aa7</ClientId><Version xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">1.2.183.57</Version></ClientVersionHeader><ContractVersionHeader xmlns="http://becwebservice.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><BecVersion xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">Version47</BecVersion></ContractVersionHeader><TrackingHeader xmlns="http://becwebservice.microsoftonline.com/">4e6cb653-c968-4a3a-8a11-2c8919218aeb</TrackingHeader><a:To s:mustUnderstand="1">https://provisioningapi.microsoftonline.com/provisioningwebservice.svc</a:To></s:Header><s:Body><ListUsers xmlns="http://provisioning.microsoftonline.com/"><request xmlns:b="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><b:BecVersion>Version16</b:BecVersion><b:TenantId>$($tenantid)</b:TenantId><b:VerifiedDomain i:nil="true"/><b:UserSearchDefinition xmlns:c="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration"><c:PageSize>500</c:PageSize><c:SearchString i:nil="true"/><c:SortDirection>Ascending</c:SortDirection><c:SortField>None</c:SortField><c:AccountSku i:nil="true"/><c:BlackberryUsersOnly i:nil="true"/><c:City i:nil="true"/><c:Country i:nil="true"/><c:Department i:nil="true"/><c:DomainName i:nil="true"/><c:EnabledFilter i:nil="true"/><c:HasErrorsOnly i:nil="true"/><c:IncludedProperties i:nil="true" xmlns:d="http://schemas.microsoft.com/2003/10/Serialization/Arrays"/><c:IndirectLicenseFilter i:nil="true"/><c:LicenseReconciliationNeededOnly i:nil="true"/><c:ReturnDeletedUsers i:nil="true"/><c:State i:nil="true"/><c:Synchronized i:nil="true"/><c:Title i:nil="true"/><c:UnlicensedUsersOnly i:nil="true"/><c:UsageLocation i:nil="true"/></b:UserSearchDefinition></request></ListUsers></s:Body></s:Envelope>
"@
    $userlist = do {
        if ($null -eq $page) {
            $Page = (Invoke-RestMethod -Uri 'https://provisioningapi.microsoftonline.com/provisioningwebservice.svc' -Method post -Body $MSOLXML -ContentType 'application/soap+xml; charset=utf-8').envelope.body.ListUsersResponse.listusersresult.returnvalue
            $Page.results.user
        }
        else {
            $Page = (Invoke-RestMethod -Uri 'https://provisioningapi.microsoftonline.com/provisioningwebservice.svc' -Method post -Body $MSOLXML -ContentType 'application/soap+xml; charset=utf-8').envelope.body.NavigateUserResultsResponse.NavigateUserResultsResult.returnvalue
            $Page.results.user
        }
        $MSOLXML = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing"><s:Header><a:Action s:mustUnderstand="1">http://provisioning.microsoftonline.com/IProvisioningWebService/NavigateUserResults</a:Action><a:MessageID>urn:uuid:$TrackingGuid</a:MessageID><a:ReplyTo><a:Address>http://www.w3.org/2005/08/addressing/anonymous</a:Address></a:ReplyTo><UserIdentityHeader xmlns="http://provisioning.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><BearerToken xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">$($AADGraphtoken['Authorization'])</BearerToken><LiveToken i:nil="true" xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService"/></UserIdentityHeader><BecContext xmlns="http://becwebservice.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><DataBlob xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">$DataBlob</DataBlob><PartitionId xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">130</PartitionId></BecContext><ClientVersionHeader xmlns="http://provisioning.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><ClientId xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">50afce61-c917-435b-8c6d-60aa5a8b8aa7</ClientId><Version xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">1.2.183.57</Version></ClientVersionHeader><ContractVersionHeader xmlns="http://becwebservice.microsoftonline.com/" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><BecVersion xmlns="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService">Version47</BecVersion></ContractVersionHeader><TrackingHeader xmlns="http://becwebservice.microsoftonline.com/">$($TrackingGuid)</TrackingHeader><a:To s:mustUnderstand="1">https://provisioningapi.microsoftonline.com/provisioningwebservice.svc</a:To></s:Header><s:Body><NavigateUserResults xmlns="http://provisioning.microsoftonline.com/"><request xmlns:b="http://schemas.datacontract.org/2004/07/Microsoft.Online.Administration.WebService" xmlns:i="http://www.w3.org/2001/XMLSchema-instance"><b:BecVersion>Version16</b:BecVersion><b:TenantId>$($tenantid)</b:TenantId><b:VerifiedDomain i:nil="true"/><b:ListContext>$($page.listcontext)</b:ListContext><b:PageToNavigate>Next</b:PageToNavigate></request></NavigateUserResults></s:Body></s:Envelope>
"@
    } until ($page.IsLastPage -eq $true -or $null -eq $page)
    return $userlist
}

function New-DeviceLogin {
    [CmdletBinding()]
    param (
        [string]$clientid,
        [string]$scope,
        [switch]$FirstLogon,
        [string]$device_code,
        [string]$TenantId
    )
    $encodedscope = [uri]::EscapeDataString($scope)
    if ($FirstLogon) {
        if ($TenantID) {
            $ReturnCode = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$($TenantID)/oauth2/v2.0/devicecode" -Method POST -Body "client_id=$($Clientid)&scope=$encodedscope+offline_access+profile+openid"

        }
        else {
            $ReturnCode = Invoke-RestMethod -Uri "https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode" -Method POST -Body "client_id=$($Clientid)&scope=$encodedscope+offline_access+profile+openid"
        }
    }
    else {
        $Checking = Invoke-RestMethod -SkipHttpErrorCheck -Uri "https://login.microsoftonline.com/organizations/oauth2/v2.0/token" -Method POST -Body "client_id=$($Clientid)&scope=$encodedscope+offline_access+profile+openid&grant_type=device_code&device_code=$($device_code)"
        if ($checking.refresh_token) {
            $ReturnCode = $Checking
        }
        else {
            $returncode = $Checking.error
        }
    }
    return $ReturnCode
}