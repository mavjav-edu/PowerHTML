#requires -version 5
#Build Script for Powershell Modules
#Uses Invoke-Build (https://github.com/nightroman/Invoke-Build)
#Run by changing to the project root directory and run ./Invoke-Build.ps1
#Uses a Master-Always-deploys strategy and semantic versioning - Http://Nvie.Com/Posts/A-Successful-Git-Branching-model/

param (
    #Skip publishing to various destinations (Appveyor,Github,PowershellGallery,etc.)
    [Switch]$SkipPublish,
    #Force deployment step even if we are not in master. If you are following GitFlow or GitHubFlow you should never need to do this.
    [Switch]$ForceDeploy,
    #Show detailed environment variables
    [Switch]$ShowEnvironmentVariables,
    #Powershell modules required for the build process
    [String[]]$BuildHelperModules = @('BuildHelpers', 'Pester', 'Powershell-Yaml', 'Microsoft.Powershell.Archive', 'PSScriptAnalyzer'),
    #Which build files/folders should be excluded from packaging
    [String[]]$BuildFilesToExclude = @('Build', 'BuildOutput', 'Tests', '.git*', 'appveyor.yml', 'gitversion.yml', '*.build.ps1', '.vscode', '.placeholder'),
    #NuGet API Key for Powershell Gallery Deployment. Defaults to environment variable of the same name
    [String]$NuGetAPIKey = $env:NuGetAPIKey,
    #GitHub User for Github Releases. Defaults to environment variable of the same name
    [String]$GitHubUserName = $env:GitHubUserName,
    #GitHub API Key for Github Releases. Defaults to environment variable of the same name
    [String]$GitHubAPIKey = $env:GitHubAPIKey
)

#Initialize Build Environment
Enter-Build {
    #Initialize Script-scope variables
    $ArtifactPaths = @()
    $ProjectBuildVersion = $null
    $ProjectBuildPath = $null

    $lines = '----------------------------------------------------------------'
    function Write-VerboseHeader ([String]$Message)
    {
        #Simple function to add lines around a header
        Write-Verbose ''
        Write-Verbose $lines
        Write-Verbose $Message
        Write-Verbose $lines
    }

    #Detect if we are in a continuous integration environment (Appveyor, etc.) or otherwise running noninteractively
    if ($ENV:CI -or ([Environment]::GetCommandLineArgs() -like '-noni*'))
    {
        Write-Build Green 'Build Initialization: Detected a Noninteractive or CI environment, disabling prompt confirmations'
        $SCRIPT:CI = $true
        $ConfirmPreference = 'None'
        $ProgressPreference = 'SilentlyContinue'
    }

    #Fetch Build Helper Modules using Install-ModuleBootstrap script (works in PSv3/4)
    #The comma in ArgumentList a weird idiosyncracy to make sure a nested array is created to ensure Argumentlist
    #doesn't unwrap the buildhelpermodules as individual arguments
    #We suppress verbose output for master builds (because they should have already been built once cleanly)

    foreach ($BuildHelperModuleItem in $BuildHelperModules)
    {
        if (-not (Get-Module $BuildHelperModuleItem -ListAvailable))
        {
            Write-Verbose "Build Initialization: Installing $BuildHelperModuleItem from Powershell Gallery to your currentuser module directory"
            if ($PSVersionTable.PSVersion.Major -lt 5)
            {
                Write-Verboseheader "Bootstrapping Powershell Module: $BuildHelperModuleItem"
                Invoke-Command -ArgumentList @(, $BuildHelperModules) -ScriptBlock ([scriptblock]::Create((New-Object net.webclient).DownloadString('https://git.io/PSModBootstrap')))
            }
            else
            {
                $installModuleParams = @{
                    Scope       = 'CurrentUser'
                    Name        = $BuildHelperModuleItem
                    ErrorAction = 'Stop'
                }
                if ($SCRIPT:CI)
                {
                    $installModuleParams.Force = $true
                }
                Install-Module @installModuleParams
            }
        }
    }

    #Initialize helpful build environment variables
    $Timestamp = Get-Date -UFormat '%Y%m%d-%H%M%S'
    $PSVersion = $PSVersionTable.PSVersion.Major
    Set-BuildEnvironment -Force

    $PassThruParams = @{}

    #If the branch name is Master-Test, run the build like we are in "master"
    if ($env:BHBranchName -eq 'Master-Test')
    {
        Write-Build Magenta 'Detected Master-Test branch, running as if we were master'
        $SCRIPT:BranchName = 'master'
    }
    else
    {
        $SCRIPT:BranchName = $env:BHBranchName
    }
    Write-Build Green "Current Branch Name: $BranchName"

    if ( ($VerbosePreference -ne 'SilentlyContinue') -or ($CI -and ($BranchName -ne 'master')) )
    {
        Write-Build Green 'Build Initialization: Verbose Build Logging Enabled'
        $SCRIPT:VerbosePreference = 'Continue'
        $PassThruParams.Verbose = $true
    }


    Write-Verboseheader 'Build Environment Prepared! Environment Information:'
    Get-BuildEnvironment | Format-List | Out-String | Write-Verbose
    if ($ShowEnvironmentVariables)
    {
        Write-Verboseheader 'Current Environment Variables'
        Get-ChildItem env: | Out-String | Write-Verbose

        Write-Verboseheader 'Powershell Variables'
        Get-Variable | Select-Object name, value, visibility | Format-Table -AutoSize | Out-String | Write-Verbose
    }

    #Register Nuget
    if (!(Get-PackageProvider 'Nuget' -ForceBootstrap -ErrorAction silentlycontinue))
    {
        Write-Verbose 'Nuget Provider Not found. Fetching...'
        Install-PackageProvider Nuget -ForceBootstrap -Scope currentuser @PassThruParams | Out-String | Write-Verbose
        Write-Verboseheader 'Installed Nuget Provider Info'
        Get-PackageProvider Nuget @PassThruParams | Format-List | Out-String | Write-Verbose
    }

    #A bug with the Appveyor 2017 image having a broken nuget (points to v3 URL but installed packagemanagement doesn't query v3 correctly)
    #Next command will add this back
    if ($ENV:APPVEYOR -and ($ENV:APPVEYOR_BUILD_WORKER_IMAGE -eq 'Visual Studio 2017'))
    {
        Write-Verbose 'Detected Appveyor VS2017 Image, using v2 Nuget API'
        Unregister-PackageSource -Name nuget.org
    }

    #Add the nuget repository so we can download things like GitVersion
    if (!(Get-PackageSource 'nuget.org' -ErrorAction silentlycontinue))
    {
        Write-Verbose 'Registering nuget.org as package source'
        Register-PackageSource -provider NuGet -Name nuget.org -Location http://www.nuget.org/api/v2 -Trusted @PassThruParams | Out-String | Write-Verbose
    }
    else
    {
        $nugetOrgPackageSource = Set-PackageSource -Name 'nuget.org' -Trusted @PassThruParams
        if ($PassThruParams.Verbose)
        {
            Write-Verboseheader 'Nuget.Org Package Source Info '
            $nugetOrgPackageSource | Format-Table | Out-String | Write-Verbose
        }
    }

    #Move to the Project Directory if we aren't there already
    Set-Location $buildRoot

    #Define the Project Build Path
    $SCRIPT:ProjectBuildPath = $ENV:BHBuildOutput + '\' + $ENV:BHProjectName
    Write-Build Green "Module Build Output Path: $ProjectBuildPath"

    #Force TLS 1.2 for all HTTPS transactions
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

task Clean {
    #Reset the BuildOutput Directory
    if (Test-Path $env:BHBuildOutput)
    {
        Write-Verbose "Removing and resetting Build Output Path: $($ENV:BHBuildOutput)"
        Remove-Item $env:BHBuildOutput -Recurse -Force @PassThruParams
    }
    New-Item -ItemType Directory $ProjectBuildPath -Force | ForEach-Object FullName | Out-String | Write-Verbose
    #Unmount any modules named the same as our module

}

task Version {
    #This task determines what version number to assign this build
    $GitVersionConfig = "$buildRoot/GitVersion.yml"

    #Fetch GitVersion
    #TODO: Use Nuget.exe to fetch to make this v3/v4 compatible
    $GitVersionCMDPackageName = 'gitversion.commandline'
    $GitVersionCMDPackage = Get-Package $GitVersionCMDPackageName -ErrorAction SilentlyContinue
    if (!($GitVersionCMDPackage))
    {
        Write-Verbose "Package $GitVersionCMDPackageName Not Found Locally, Installing..."
        Write-VerboseHeader 'Nuget.Org Package Source Info for fetching GitVersion'
        Get-PackageSource | Format-Table | Out-String | Write-Verbose

        #Fetch GitVersion
        $GitVersionCMDPackage = Install-Package $GitVersionCMDPackageName -Scope currentuser -Source 'nuget.org' -Force @PassThruParams
    }
    $GitVersionEXE = (Get-Package $GitVersionCMDPackageName).source | Split-Path -Parent -Resolve | ForEach-Object { Resolve-Path "$_\*\*.exe" } | Select-Object -First 1

    #Does this project have a module manifest? Use that as the Gitversion starting point (will use this by default unless project is tagged higher)
    #Uses Powershell-YAML module to read/write the GitVersion.yaml config file
    if (Test-Path $env:BHPSModuleManifest)
    {
        Write-Verbose 'Fetching Version from Powershell Module Manifest (if present)'
        $ModuleManifestVersion = [Version](Get-Metadata $env:BHPSModuleManifest)
        if (Test-Path $buildRoot/GitVersion.yml)
        {
            $GitVersionConfigYAML = [ordered]@{}
            #ConvertFrom-YAML returns as individual Key-Value hashtables, we need to combine them into a single hashtable
            (Get-Content $GitVersionConfig | ConvertFrom-Yaml) | ForEach-Object { $GitVersionConfigYAML += $PSItem }
            if ($GitVersionConfigYAML.'next-version' -ne $ModuleManifestVersion.ToString())
            {
                $GitVersionConfigYAML.'next-version' = $ModuleManifestVersion.ToString()
                $GitVersionConfigYAML | ConvertTo-Yaml | Out-File $GitVersionConfig
            }
        }
        else
        {
            @{'next-version' = $ModuleManifestVersion.toString() } | ConvertTo-Yaml | Out-File $GitVersionConfig
        }
    }

    #Calcuate the GitVersion
    Write-Verbose 'Executing GitVersion to determine version info'
    $GitVersionOutput = Invoke-BuildExec { & $GitVersionEXE $buildRoot }

    #Since GitVersion doesn't return error exit codes, we look for error text in the output in the output
    if ($GitVersionOutput -match '^[ERROR|INFO] \[') { throw "An error occured when running GitVersion.exe $buildRoot" }
    try
    {
        $GitVersionInfo = $GitVersionOutput | ConvertFrom-Json -ErrorAction stop
    }
    catch
    {
        throw "There was an error when running GitVersion.exe $buildRoot. The output of the command (if any) follows:"
        $GitVersionOutput
    }

    Write-Verboseheader 'GitVersion Results'
    $GitVersionInfo | Format-List | Out-String | Write-Verbose

    #If we are in the develop branch, add the prerelease number as revision
    #TODO: Make the develop and master regex customizable in a settings file
    if ($BranchName -match '^dev(elop)?(ment)?$')
    {
        $SCRIPT:ProjectBuildVersion = ($GitVersionInfo.MajorMinorPatch + '.' + $GitVersionInfo.PreReleaseNumber)
    }
    else
    {
        $SCRIPT:ProjectBuildVersion = [Version] $GitVersionInfo.MajorMinorPatch
    }


    $SCRIPT:ProjectSemVersion = $($GitVersionInfo.fullsemver)
    Write-Build Green "Task $($task.name)`: Using Project Version: $ProjectBuildVersion"
    Write-Build Green "Task $($task.name)`: Using Project Version (Extended): $($GitVersionInfo.fullsemver)"
}

#Copy all powershell module "artifacts" to Build Directory
task CopyFilesToBuildDir {
    #Make sure we are in the project location in case somethign changedf
    Set-Location $buildRoot

    #The file or file paths to copy, excluding the powershell psm1 and psd1 module and manifest files which will be autodetected
    #TODO: Move this somewhere higher in the hierarchy into a settings file, or rather go the "exclude" route
    $FilesToCopy = 'lib', 'Public', 'Private', 'Types', 'LICENSE', 'README.md', "$($Env:BHProjectName).psm1", "$($Env:BHProjectName).psd1"
    Copy-Item -Recurse -Path $buildRoot\* -Exclude $BuildFilesToExclude -Destination $ProjectBuildPath @PassThruParams
}

#Update the Metadata of the Module with the latest Version
task UpdateMetadata CopyFilesToBuildDir, Version, {
    # Load the module, read the exported functions, update the psd1 FunctionsToExport
    # Because this loads/locks assembiles and can affect cleans in the same session, copy it to a temporary location, find the changes, and apply to original module.
    # TODO: Find a cleaner solution, like update Set-ModuleFunctions to use a separate runspace or include a market to know we are in ModuleFunctions so when loading the module we can copy the assemblies to temp files first
    $ProjectBuildManifest = ($ProjectBuildPath + '\' + (Split-Path $env:BHPSModuleManifest -Leaf))
    $tempModuleDir = [System.IO.Path]::GetTempFileName()
    Remove-Item $tempModuleDir -Verbose:$false
    New-Item -Type Directory $tempModuleDir | Out-Null
    Copy-Item -Recurse $ProjectBuildPath/* $tempModuleDir

    $TempModuleManifest = ($tempModuleDir + '\' + (Split-Path $env:BHPSModuleManifest -Leaf))
    Set-ModuleFunctions $tempModuleManifest @PassThruParams
    $moduleFunctionsToExport = Get-Metadata -Path $tempModuleManifest -PropertyName FunctionsToExport
    Update-Metadata -Path $ProjectBuildManifest -PropertyName FunctionsToExport -Value $moduleFunctionsToExport

    # Set the Module Version to the calculated Project Build version
    Update-Metadata -Path $ProjectBuildManifest -PropertyName ModuleVersion -Value $ProjectBuildVersion

    # Are we in the master or develop/development branch? Bump the version based on the powershell gallery if so, otherwise add a build tag
    if ($BranchName -match '^(master|dev(elop)?(ment)?)$')
    {
        Write-Build Green "Task $($task.name)`: In Master/Develop branch, adding Tag Version $ProjectBuildVersion to this build"
        $Script:ProjectVersion = $ProjectBuildVersion
        if (-not (git tag -l $ProjectBuildVersion))
        {
            git tag "$ProjectBuildVersion"
        }
        else
        {
            Write-Warning "Tag $ProjectBuildVersion already exists. This is normal if you are running multiple builds on the same commit, otherwise this should not happen"
        }
        <# TODO: Add some intelligent logic to tagging releases
        if (-not $CI) {
            git push origin $ProjectBuildVersion | Write-Verbose
        }
        #>
        <# TODO: Add a Powershell Gallery Check on the module
        if (Get-NextNugetPackageVersion -Name (Get-ProjectName) -ErrorAction SilentlyContinue) {
            Update-Metadata -Path $env:BHPSModuleManifest -PropertyName ModuleVersion -Value (Get-NextNugetPackageVersion -Name (Get-ProjectName))
        }
        #>
    }
    else
    {
        Write-Build Green "Task $($task.name)`: Not in Master/Develop branch, marking this as a feature prelease build"
        $Script:ProjectVersion = $ProjectSemVersion
        #Set an email address for tag commit to work if it isn't already present
        if (-not (git config user.email))
        {
            git config user.email "buildtag@$env:ComputerName"
            $tempTagGitEmailSet = $true
        }
        try
        {
            $gitVersionTag = "v$ProjectSemVersion"
            if (-not (git tag -l $gitVersionTag))
            {
                exec { git tag "$gitVersionTag" -a -m 'Automatic GitVersion Prerelease Tag Generated by Invoke-Build' }
            }
            else
            {
                Write-Warning "Tag $gitVersionTag already exists. This is normal if you are running multiple builds on the same commit, otherwise this should not happen"
            }
        }
        finally
        {
            if ($tempTagGitEmailSet)
            {
                git config --unset user.email
            }
        }


        #Create an empty file in the root directory of the module for easy identification that its not a valid release.
        'This is a prerelease build and not meant for deployment!' > (Join-Path $ProjectBuildPath "PRERELEASE-$ProjectSemVersion")
    }

    # Add Release Notes from current version
    # TODO: Generate Release Notes from Github
    #Update-Metadata -Path $env:BHPSModuleManifest -PropertyName ReleaseNotes -Value ("$($env:APPVEYOR_REPO_COMMIT_MESSAGE): $($env:APPVEYOR_REPO_COMMIT_MESSAGE_EXTENDED)")
}

#Pester Testing
task Pester {
    $BuildOutputProject = Join-Path $env:BHBuildOutput $env:BHProjectName
    $ModuleManifestPath = Join-Path $BuildOutputProject '\*.psd1'
    if (-not (Test-Path $ModuleManifestPath)) { throw "Module Manifest not found at $ModuleManifestPath. Did you run 'Invoke-Build Build' first?" }

    Write-Verboseheader 'Starting Pester Tests...'
    $PesterResultFile = "$($env:BHBuildOutput)\$($env:BHProjectName)-TestResults_PS$PSVersion`_$TimeStamp.xml"

    $PesterParams = @{
        Script       = 'Tests'
        OutputFile   = $PesterResultFile
        OutputFormat = 'NunitXML'
        PassThru     = $true
    }

    #If we are in vscode, add the VSCodeMarkers
    if ($host.name -match 'Visual Studio Code')
    {
        Write-Verbose 'Detected Visual Studio Code, adding test markers'
        $PesterParams.PesterOption = (New-PesterOption -IncludeVSCodeMarker)
    }

    Invoke-Pester @PesterParams | Out-Null

    # In Appveyor?  Upload our test results!
    If ($ENV:APPVEYOR)
    {
        $UploadURL = "https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)"
        Write-Verbose 'Detected we are running in AppVeyor'
        Write-Verbose "Uploading Pester Results to Appveyor: $UploadURL"
        (New-Object 'System.Net.WebClient').UploadFile(
            "https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)",
            $PesterResultFile )
    }

    # Failed tests?
    # Need to error out or it will proceed to the deployment. Danger!
    if ($TestResults.FailedCount -gt 0)
    {
        Write-Error "Failed '$($TestResults.FailedCount)' tests, build failed"
    }
    "`n"
}

task Package Version, {

    $ZipArchivePath = (Join-Path $env:BHBuildOutput "$env:BHProjectName-$ProjectBuildVersion.zip")
    Write-Build green "Task $($task.name)`: Writing Finished Module to $ZipArchivePath"
    #Package the Powershell Module
    Compress-Archive -Path $ProjectBuildPath -DestinationPath $ZipArchivePath -Force @PassThruParams

    $SCRIPT:ArtifactPaths += $ZipArchivePath
    #If we are in Appveyor, push completed zip to Appveyor Artifact
    if ($env:APPVEYOR)
    {
        Write-Build Green "Task $($task.name)`: Detected Appveyor, pushing Powershell Module archive to Artifacts"
        Push-AppveyorArtifact $ZipArchivePath
    }
}

task PreDeploymentChecks {
    #Do not proceed if the most recent Pester test is not passing.
    $CurrentErrorActionPreference = $ErrorActionPreference
    try
    {
        $ErrorActionPreference = 'Stop'
        $MostRecentPesterTestResult = [xml]((Get-Content -Raw (Get-Item "$ENV:BHBuildOutput/*-TestResults*.xml" | Sort-Object lastwritetime | Select-Object -Last 1)))
        $MostRecentPesterTestResult = $MostRecentPesterTestResult.'Test-Results'
        if (
            $MostRecentPesterTestResult -isnot [System.XML.XMLElement] -or
            $MostRecentPesterTestResult.errors -gt 0 -or
            $MostRecentPesterTestResult.failures -gt 0
        ) { throw 'Fail!' }
    }
    catch
    {
        throw "Unable to detect a clean passing Pester Test nunit xml file in the $env:BHBuildOutput directory. Did you run {Invoke-Build Build,Test} and ensure it passed all tests first?"
    }
    finally
    {
        $ErrorActionPreference = $CurrentErrorActionPreference
    }

    if (($env:BHBranchName -eq 'master') -or $ForceDeploy)
    {
        if (-not (Get-Item $ProjectBuildPath/*.psd1 -ErrorAction silentlycontinue)) { throw "No Powershell Module Found in $ProjectBuildPath. Skipping deployment. Did you remember to build it first with {Invoke-Build Build}?" }
    }
    else
    {
        Write-Build Magenta "Task $($task.name)`: We are not in master branch, skipping publish. If you wish to deploy anyways such as for testing, run {InvokeBuild Deploy -ForceDeploy:$true}"
        $script:SkipPublish = $true
    }
}

task PublishGitHubRelease -if (-not $SkipPublish) Package, {
    #TODO: Add Prerelease Logic when message commit says "!prerelease" or is in a release branch
    if ($AppVeyor -and -not $GitHubAPIKey)
    {
        Write-Build DarkYellow "Task PublishGitHubRelease: Couldn't find GitHubAPIKey in the Appveyor secure environment variables. Did you save your Github API key as an Appveyor Secure Variable? Https://Docs.Microsoft.Com/En-Us/Powershell/Gallery/Psgallery/Creating-And-Publishing-An-item and https://github.com/settings/tokens"
        $SkipGitHubRelease = $true
    }
    if (-not $GitHubAPIKey)
    {
        #TODO: Add Windows Credential Store support and some kind of Linux secure storage or caching option
        Write-Build DarkYellow 'Task PublishGitHubRelease: $env:GitHubAPIKey was not found as an environment variable. Please specify it or use {Invoke-Build Deploy -GitHubUser "MyGitHubUser" -GitHubAPIKey "MyAPIKeyString"}. Have you created a GitHub API key with minimum public_repo scope permissions yet? https://github.com/settings/tokens'
        $SkipGitHubRelease = $true
    }
    if (-not $GitHubUserName)
    {
        Write-Build DarkYellow 'Task PublishGitHubRelease: $env:GitHubUserName was not found as an environment variable. Please specify it or use {Invoke-Build Deploy -GitHubUser "MyGitHubUser" -GitHubAPIKey "MyAPIKeyString"}. Have you created a GitHub API key with minimum public_repo scope permissions yet? https://github.com/settings/tokens'
        $SkipGitHubRelease = $true
    }
    if ($SkipGitHubRelease)
    {
        Write-Build Magenta "Task $($task.name): Skipping Publish to GitHub Releases"
    }
    else
    {
        #TODO: Add Prerelease Logic when message commit says "!prerelease" or is in a release branch
        #Inspiration from Https://Www.Herebedragons.Io/Powershell-Create-Github-Release-With-Artifact

        #Create the release
        $releaseData = @{
            tag_name         = [string]::Format('v{0}', $ProjectBuildVersion);
            target_commitish = 'master';
            name             = [string]::Format('v{0}', $ProjectBuildVersion);
            body             = $env:BHCommitMessage;
            draft            = $true;
            prerelease       = $true;
        }
        $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($GitHubApiKey + ':x-Oauth-Basic'))
        $releaseParams = @{
            Uri         = "https://api.github.com/repos/$gitHubUserName/$env:BHProjectName/releases"
            Method      = 'POST'
            Headers     = @{
                Authorization = $auth
            }
            ContentType = 'application/json'
            Body        = (ConvertTo-Json $releaseData -Compress)
        }

        $result = Invoke-RestMethod @releaseParams -ErrorAction stop

        $uploadUriBase = $result.upload_url -creplace '\{\?name,label\}'  # Strip the , "?name=$artifact" part

        $uploadParams = @{
            Method      = 'POST';
            Headers     = @{
                Authorization = $auth;
            }
            ContentType = 'application/zip';
        }
        foreach ($artifactItem in $artifactPaths)
        {
            $uploadparams.URI = $uploadUriBase + "?name=$(Split-Path $artifactItem -Leaf)"
            $uploadparams.Infile = $artifactItem
            $result = Invoke-RestMethod @uploadParams -ErrorAction stop
        }
    }
}

#TODO: Replace SkipPublish Logic with Proper invokebuild task skipping
task PublishPSGallery -if (-not $SkipPublish) {
    if ($AppVeyor -and -not $NuGetAPIKey)
    {
        Write-Build DarkYellow "Couldn't find NuGetAPIKey in the Appveyor secure environment variables. Did you save your NuGet/Powershell Gallery API key as an Appveyor Secure Variable? Https://Docs.Microsoft.Com/En-Us/Powershell/Gallery/Psgallery/Creating-And-Publishing-An-item and Https://Www.Appveyor.Com/Docs/Build-Configuration/"
        $SkipPSGallery = $true
    }
    if (-not $NuGetAPIKey)
    {
        #TODO: Add Windows Credential Store support and some kind of Linux secure storage or caching option
        Write-Build DarkYellow '$env:NuGetAPIKey was not found as an environment variable. Please specify it or use {Invoke-Build Deploy -NuGetAPIKey "MyAPIKeyString"}. Have you registered for a Powershell Gallery API key yet? Https://Docs.Microsoft.Com/En-Us/Powershell/Scripting/Gallery/How-To/Publishing-Packages/publishing-a-package?view=powershell-7.2'
        $SkipPSGallery = $true
    }

    if ($SkipPublish)
    {
        Write-Build Magenta "Task $($task.name)`: Skipping Powershell Gallery Publish"
    }
    else
    {
        $publishParams = @{
            Path        = $ProjectBuildPath
            NuGetApiKey = $NuGetAPIKey
            Repository  = 'PSGallery'
            Force       = $true
            ErrorAction = 'Stop'
            Confirm     = $false
        }
        #TODO: Add Prerelease Logic when message commit says "!prerelease"
        Publish-Module @publishParams @PassThruParams
    }
}

### SuperTasks
# These are the only supported items to run directly from Invoke-Build
task Deploy PreDeploymentChecks, Package, PublishGitHubRelease, PublishPSGallery
task Build Clean, CopyFilesToBuildDir, UpdateMetadata
task Test Pester

#Default Task - Build, Test with Pester, Deploy
task . Clean, Build, Test, Deploy