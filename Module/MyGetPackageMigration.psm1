<#
    .SYNOPSIS
        Migrate NuGet Packages From MyGet to Azure DevOps

    .DESCRIPTION
        This function copies all NuGet packages from a MyGet.org public feed
        to an Azure DevOps project feed. This requires a password from your
        Azure DevOps organization. Passowrd can be in the form of a PAT (Personal Access Token)

    .PARAMETER SourceIndexUrl
        The Index URL from your MyGet Package feed.

    .PARAMETER DestinationIndexUrl
        The Index URL of your Azure DevOps feed.

    .PARAMETER DestinationPAT
        Azure DevOps Personal Access Token (PAT) string

    .PARAMETER TempFilePath
        A file path where a .nupkg will be created during migration. 
        This is automatically cleaned up.
    
    .PARAMETER SourceUsername
        The username of your Source pacakgeing provider

    .PARAMETER SourcePassword
        A string password to your package source. Password is encrypted before 
        being used in any webrequests.

    .PARAMETER NumVersions
        The number of versions you would like of any given package.

    .PARAMETER Verbose
        Switch to turn on verbose messaging.

    .EXAMPLE
        # Create a Hashtable to splat to your 'Move-MyGetNuGetPackages'
        $params = @{
            SourceIndexUrl      = 'https://www.myget.org/F/mytestfeed/api/v3/index.json'
            DestinationIndexUrl = 'https://pkgs.dev.azure.com/mytestorg/_packaging/mynewtestfeed/nuget/v3/index.json'
            DestinationPassword = 'thisisafakepassword'
            TempFilePath        = 'C:/Temp/'
            FeedName            = 'mynewtestfeed'
        }

        Move-MyGetNuGetPackages @params

    .NOTES
        For more information on Personal Access Tokens - https://docs.microsoft.com/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate
#>
function Move-MyGetNuGetPackages
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $SourceIndexUrl,

        [Parameter(Mandatory = $true)]
        [string]
        $DestinationIndexUrl,

        [Parameter(Mandatory = $true)]
        [string]
        $DestinationPAT,

        [Parameter()]
        [string]
        $TempFilePath = $env:Temp,

        [Parameter()]
        [string]
        $SourceUsername,

        [Parameter()]
        [securestring]
        $SourcePassword,

        [Parameter()]
        [string]
        $DestinationFeedName,

        [Parameter()]
        [int[]]
        $NumVersions = $null,

        [Parameter()]
        [switch]
        $Verbose
    )

    if ($null -eq $TempFilePath)
    {
        $TempFilePath = [System.IO.Path]::GetTempPath()

        if ($null -eq $TempFilePath)
        {
            Write-Error 'Temp filepath not found. Please provide value for -TempFilePath'
            throw
        }
    }

    if ($Verbose)
    {
        $oldVerbosePreference = $VerbosePreference
        $VerbosePreference = 'Continue'
    }

    if ($DestinationFeedName)
    {
        # Adds Azure DevOps feed to NuGet sources/ update password to access feed. 
        # It also prevent's further progress if NuGet is not set up correctly for migration on the users machine.
        Update-NuGetSource -FeedName $DestinationFeedName -DevOpsSourceUrl $DestinationIndexUrl -Password $DestinationPAT
    }

    if ($SourcePassword)
    {
        $sourceCredential = New-Object -TypeName pscredential -ArgumentList $SourceUsername, $secureSourcePassword
    }

    $securePassword = ConvertTo-SecureString -String $DestinationPAT -AsPlainText -Force
    $destinationCredential = New-Object -TypeName pscredential -ArgumentList 'PackageMigration', $securePassword

    # Collects and compares packages from source to Azure DevOps feed
    $sourceVersions = Get-ContentUrls -IndexUrl $SourceIndexUrl -NumVersions $NumVersions -Credential $sourceCredential
    $destinationVersions = Get-Packages -IndexUrl $DestinationIndexUrl -Credential $destinationCredential
    $versionsMissingInDestination = Get-MissingVersions -SourceVersions $sourceVersions -DestinationVersions $destinationVersions
    $message = "Found $($sourceVersions.Count) package titles in source, $($destinationVersions.Count) package titles in destination, and $($versionsMissingInDestination.Count) packages titles need to be copied"
    Write-Verbose $message
    $versionContentUrls = $versionsMissingInDestination.Url

    # Migrates packages from sources to Azure DevOps feed
    $results = Start-MigrationSingleThreaded -ContentUrls $versionContentUrls -DestinationIndexUrl $DestinationIndexUrl -TempFilePath $TempFilePath -SourceCredential $sourceCredential

    Out-Results $results
    $VerbosePreference = $oldVerbosePreference
}

<#
    .SYNOPSIS
        Returns the NuGet connection URLs

    .PARAMETER IndexUrl
        The Index URL from your MyGet Package feed.

    .PARAMETER NumVersions
        The Index URL of your Azure DevOps feed.

    .PARAMETER Credential
        The credential object to connect to packaging source.
#>
function Get-ContentUrls
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $IndexUrl,

        [Parameter()]
        [int[]]
        $NumVersions = $null, 

        [Parameter()]
        [AllowNull()]
        [pscredential]
        $Credential
    )

    # Var is used to ensure there aren't multiple requests to package urls
    $Script:registrationRequests = [System.Collections.ArrayList]::new()
    $packages = (Get-Packages -IndexUrl $IndexUrl -NumVersions $NumVersions -Credential $Credential).id | Select-Object -Unique

    #TODO need to edit the received packages to make sure I'm only getting the unique packages
    $registrationBaseUrl = Get-RegistrationBase -IndexUrl $IndexUrl -Credential $Credential
    $result = [System.Collections.ArrayList]::new()

    # Collect source package URLs to migrate
    foreach ($packageName in $packages)
    {
        $registrationUrl = "$registrationBaseUrl/$packageName/index.json"
        $versions = Read-CatalogUrl -RegistrationUrl $registrationUrl -Credential $Credential
        $null = $result.Add($versions)
        if ($null -ne $NumVersions -and $result.Count -ge $NumVersions)
        {
            return $result[0..$NumVersions]
        }
    }

    return $result
}

<#
    .SYNOPSIS
        Filters and returns the NuGet v3 URL

    .PARAMETER IndexUrl
        The Index URL from your MyGet Package feed.

    .PARAMETER Credential
        The credential object to connect to packaging source.
#>
function Get-V3SearchBaseURL
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $IndexUrl,

        [Parameter()]
        [pscredential]
        $Credential
    )

    $indexJson = Get-Index -IndexUrl $IndexUrl -Credential $Credential
    $entry = ($indexJson | Where-Object -FilterScript {$_.'@type' -match 'SearchQueryService.*'})[0]

    return $entry.'@id'
}

<#
    .SYNOPSIS
        This is an empty function right now for future development.

    .PARAMETER IndexUrl
        The Index URL from your desired Package feed.
#>
function Get-V3FlatBaseURL
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string[]]
        $IndexUrl
    )
}

<#
.SYNOPSIS
    Returns the base registration URL

.PARAMETER IndexUrl
    The Index URL from the desired Package feed.

.PARAMETER Credential
        The credential object to connect to packaging source.
#>
function Get-RegistrationBase
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $IndexUrl,

        [Parameter()]
        [AllowNull()]
        [pscredential]
        $Credential
    )

    $indexJson = Get-Index -IndexUrl $IndexUrl -Credential $Credential
    $entry = $entry = ($indexJson | Where-Object -FilterScript {$_.'@type' -eq 'RegistrationsBaseUrl/Versioned'})[0]

    return $entry.'@id'
}

<#
    .SYNOPSIS
        Returns the resources for different NuGet services

    .PARAMETER IndexUrl
        The Index URL from your desired Package feed.

    .PARAMETER Credential
        The Credential object to access a URL
#>
function Get-Index
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $IndexUrl,

        [Parameter()]
        [AllowNull()]
        [pscredential]
        $Credential
    )

    return (Invoke-RestMethod -Uri $IndexUrl -Credential $Credential).resources
}

<#
    .SYNOPSIS
        Returns package information from the desired source

    .PARAMETER IndexUrl
        Base Url to query from.

    .PARAMETER Credential
        Credential to access base URL where packages are stored.

    .PARAMETER NumVersions
        The Number of versions of a given package.

    .PARAMETER Take
        Identifies packages in a query
#>
function Get-Packages
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $IndexUrl,

        [Parameter()]
        [AllowNull()]
        [pscredential]
        $Credential,

        [Parameter()]
        [int[]]
        $NumVersions = $null,

        [Parameter()]
        [int]
        $Take = 100
    )

    $searchBaseUrl = Get-V3SearchBaseURL -IndexUrl $IndexUrl -Credential $Credential
    $result = [System.Collections.ArrayList]::new()
    $i = 0

    # Create the body of the query
    $payLoad = [ordered]@{
        Prerelease = $true
        SemverLevel = '2.0'
        Skip = 0
        Take = $Take
    }

    While ($true)
    {
        # Adjust the skip portion of the query to get all packages associated with URL
        $payLoad.Skip = $i * $Take
        $message = "Request: $searchBaseUrl, Prerelease = $($payload.Prerelease), SemverLevel = $($payload.SemverLevel), Skip =$($payload.Skip), Take = $($payload.Take)"
        Write-Verbose $message
        try
        {
            $response = Invoke-RestMethod -Uri $searchBaseUrl -Body $payLoad -Credential $Credential
            $packages = $response.data
            if ($packages.Count -eq 0)
            {
                break
            }

            foreach ($package in $packages)
            {
                foreach ($version in $package.versions)
                {
                    $packageObject = [PSCustomObject]@{
                        Id      = $package.id
                        Version = $version.version
                    }

                    $null = $result.add($packageObject)
                    if ($null -ne $NumVersions -and $result.Count -ge $NumVersions)
                    {
                        return $result
                    }
                }
            }

            $i++
        }
        catch
        {
            break
        }
    }

    return $result
}

<#
    .SYNOPSIS
        Reads a catalog of packages

    .PARAMETER RegistrationUrl
        The base registration URL to query with.

    .PARAMETER Credential
        The credential object to connect to packaging source.
#>
function Read-CatalogUrl
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $RegistrationUrl,

        [Parameter()]
        [AllowNull()]
        [pscredential]
        $Credential
    )

    $result = @()

    if ($RegistrationUrl -in $Script:registrationRequests)
    {
        Write-Warning -Message "Skipping duplicate request to $RegistrationUrl" -InformationAction Continue
    }
    else
    {
        Write-Verbose "Request: $RegistrationUrl"
        $response = Invoke-RestMethod -Uri $RegistrationUrl -Credential $Credential

        # Adds to track Registration requests to identify duplicate requests
        $null = $Script:registrationRequests.Add($RegistrationUrl)
        foreach ($item in $response.items)
        {
            $result += (Read-CatalogEntry -Item $item)
        }

        return $result
    }
}

<#
    .SYNOPSIS
        Returns a pacakge entry.

    .DESCRIPTION
        This is a recursive function to reach the catalog
        entries of a given Catalog URL.

    .PARAMETER Item
        The package entry from the parent catalog
#>
function Read-CatalogEntry
{
    param
    (
        [Parameter(Mandatory = $true)]
        $Item
    )

    $result = [System.Collections.ArrayList]::new()
    $itemType = $Item.'@type'

    if ($itemType -eq 'catalog:CatalogPage' -and $null -eq $item.items)
    {
        $catalogUrl = $Item.'@id'
        $null = $result.Add((Read-CatalogUrl -RegistrationUrl $catalogUrl))
    }
    elseif ($itemType -eq 'catalog:CatalogPage')
    {
        foreach ($subItem in $Item.items)
        {
            $null = $result.Add((Read-CatalogEntry -Item $subItem))
        }
    }
    elseif ($itemType -eq 'Package')
    {
        $returnItem = [PSCustomObject]@{
            Name    = $Item.catalogEntry.id
            Version = $Item.catalogEntry.version
            Url     = $Item.packageContent
        }

        $null = $result.Add($returnItem)
    }

    return $result
}

<#
    .SYNOPSIS
        Migrates packages using NuGet.exe

    .DESCRIPTION
        This function migrates packages one at a time.
        In future development, there will be an option to use multi-threading 
        to migrate packages faster.

    .PARAMETER ContentUrls
        URL's of migrating packages

    .PARAMETER DestinationIndexUrl
        Destination index URL where packages are migrating to.

    .PARAMETER TempFilePath
        The local folder path for temporary NuGet packages during migration.

    .PARAMETER SourceCredential
        The credential object to connect to the source packaging repository.
#>
function Start-MigrationSingleThreaded
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string[]]
        $ContentUrls,

        [Parameter(Mandatory = $true)]
        [string]
        $DestinationIndexUrl,

        [Parameter(Mandatory = $true)]
        [string]
        $TempFilePath,

        [Parameter()]
        [AllowNull()]
        [pscredential]
        $SourceCredential
    )

    $results = [System.Collections.ArrayList]::new()
    $TempFilePath = "$TempFilePath/temp.nupkg"

    foreach ($url in $ContentUrls)
    {
        $result = Start-Migration -ContentUrl $url -DestinationIndexUrl $DestinationIndexUrl -TempFilePath $TempFilePath -Credential $SourceCredential
        Out-Result @result
        $null = $results.Add($result)
    }

    # Clean up temp .nupkg file created during migration.
    Remove-Item -Path $TempFilePath -Force
    return $results
}

<#
    .SYNOPSIS
        Uses NuGet.exe to migrate packages from source to destination.

    .PARAMETER ContentUrl
        URL of the package to migrate.

    .PARAMETER DestinationIndexUrl
        Destination index URL where package is migrating to.
    
    .PARAMETER Credential
        The credential object to connect to packaging source.

    .PARAMETER TempFilePath
        The local folder path for temporary NuGet packages during migration.
#>
function Start-Migration
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $ContentUrl,

        [Parameter(Mandatory = $true)]
        [string]
        $DestinationIndexUrl,

        [Parameter()]
        [AllowNull()]
        [pscredential]
        $Credential,

        [Parameter()]
        [string]
        $TempFilePath
    )
    
    try
    {
        $response = Invoke-WebRequest -Uri $ContentUrl -Credential $Credential
    }
    catch
    {
        $return = @{
            Url         = $ContentUrl
            HttpStatus  = -1
            NuGetStatus = -1
            Stdout      = $null
        }

        return $return
    }

    if ($response.StatusCode -ne 200)
    {
        $return = @{
            Url         = $ContentUrl
            HttpStatus  = $response.StatusCode
            NuGetStatus = -1
            Stdout      = $null
        }

        return $return
    }
    
    # Writes packacke content bytes to temporary .nupkg file during migration
    [io.file]::WriteAllBytes($TempFilePath, $response.Content)
    $arguments = "push -Source $DestinationIndexUrl -ApiKey Migration $TempFilePath"

    $result = Start-Command -CommandTitle 'nuget.exe' -CommandArguments $arguments
    $return = @{
        Url         = $ContentUrl
        HttpStatus  = $response.StatusCode
        NuGetStatus = $result.ExitCode
        StdOut      = $result.StdOut
        StdErr      = $result.StdErr
    }

    return $return
}

<#
    .SYNOPSIS
        Writes the result of individual package migrations.

    .PARAMETER Url
        Url of the migrating package

    .PARAMETER HttpsStatus
        Http Status code returned from web request.

    .PARAMETER NugetStatus
        NuGet migration status code

    .PARAMETER StdOut
        Standard Output

    .PARAMETER StdErr
        Standard Error Output
#>
function Out-Result
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string[]]
        $Url,

        [Parameter()]
        [string]
        $HttpStatus,

        [Parameter()]
        [string]
        $NugetStatus,

        [Parameter()]
        [string]
        $StdOut,

        [Parameter()]
        [string]
        $StdErr
    )

    Write-Verbose "$Url, --> fetchContent $HttpStatus, publish $NugetStatus"
    if ($NugetStatus -ne 0 -and $null -ne $Stdout)
    {
        Write-Verbose $StdOut
    }

    if ($StdErr)
    {
        Write-Error $StdErr -InformationAction Continue
    }
}

<#
    .SYNOPSIS
        Writes the results of package migration process as a whole.

    .PARAMETER Results
        Results of the package migration
#>
function Out-Results
{
    param
    (
        [Parameter(Mandatory = $true)]
        $Results
    )

    $errors = $Results | Where-Object -FilterScript {$_.HttpStatus -ne 200 -or $_.NuGetStatus -ne 0}
    Write-Information "$($Results.Count - $errors.Count) packages pushed successfully" -InformationAction Continue

    if ($errors.Count -gt 0)
    {
        Write-Warning "$($errors.Count) errors. See error variable for more information." -InformationAction Continue
    }
}

<#
    .SYNOPSIS
        Returns package ID's from the source not located in the destination.

    .PARAMETER SourceVersions
        Source pacakges to be filtered

    .PARAMETER DestinationVersions
        Destination packages to be filtered against.
#>
function Get-MissingVersions
{
    param
    (
        [Parameter(Mandatory = $true)]
        $SourceVersions,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $DestinationVersions
    )

    $missingPackages = [System.Collections.ArrayList]::new()
    foreach ($package in $SourceVersions)
    {
        $sourcePackage = $package | Where-Object -FilterScript {$_.Name -in $DestinationVersions.Id}

        if ($sourcePackage)
        {
            $matchingDestinationPackages = ($DestinationVersions | Where-Object -FilterScript {$_.Id -eq $sourcePackage.Name}).Version
            $sourcePackage = $sourcePackage | Where-Object -FilterScript {$_.Version -notin $matchingDestinationPackages}

            if ($sourcePackage)
            {
                $null = $missingPackages.Add($sourcePackage)
            }
        }
        else
        {
            $null = $missingPackages.Add($package)
        }
    }

    return $missingPackages
}

<#
    .SYNOPSIS
        Runs NeGet using .Net to get all required information.

    .PARAMETER CommandTitle
        The .exe to run

    .PARAMETER CommandArguments
        Argument string to run with specified .exe
#>
function Start-Command
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $CommandTitle,
        
        [Parameter()]
        $CommandArguments
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $CommandTitle
    $processInfo.RedirectStandardError = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.Arguments = $CommandArguments

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    $process.WaitForExit()

    $return = [pscustomobject]@{
        StdOut = $process.StandardOutput.ReadToEnd()
        StdErr = $process.StandardError.ReadToEnd()
        ExitCode = $process.ExitCode
    }

    return $return
}

<#
    .SYNOPSIS
        Updates NuGet config file to access Azure Artifacts feed

    .PARAMETER FeedName
        Azure Artifact feed name

    .PARAMETER DevOpsSourceUrl
        Azure DevOps feed source index Url

    .PARAMETER Password
        PAT to connect to Azure DevOps Feed
#>
function Update-NuGetSource
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $FeedName,

        [Parameter(Mandatory = $true)]
        [string]
        $DevOpsSourceUrl,

        [Parameter(Mandatory = $true)]
        [string]
        $Password
    )

    $sourceAdd = Start-Command -CommandTitle 'nuget.exe' -CommandArguments "sources Add -Name $FeedName -Source $DevOpsSourceUrl"
    if ($sourceAdd.ExitCode -eq 1)
    {
        if ($sourceAdd.StdErr -match ".*name specified has already been added to the list of available package sources.*")
        {
            Write-Verbose $sourceAdd.StdErr
        }
        else
        {
            Write-Error $sourceAdd.StdErr
            throw
        }
    }

    $sourceUpdate = Start-Command -CommandTitle nuget.exe -CommandArguments "sources Update -Name $FeedName -UserName 'username' -Password $password"

    if ($sourceUpdate.ExitCode -eq 1)
    {
        Write-Error $sourceUpdate.StdErr
        throw
    }
}

Export-ModuleMember -Function 'Move-MyGetNuGetPackages'
