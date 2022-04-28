#Get public and private function definition files.
$PublicFunctions  = @( Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction SilentlyContinue )
$PrivateFunctions = @( Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction SilentlyContinue )

#Get JSON settings files
$ModuleSettings = @( Get-ChildItem -Path $PSScriptRoot\Settings\*.json -ErrorAction SilentlyContinue )

#Determine which assembly versions to load
#See if .Net Standard 2.0 is available on the system and if not, load the legacy Net 4.0 library
try {
    Add-Type -AssemblyName 'netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51' -ErrorAction Stop
    #If netstandard is not available it won't get this far
    $dotNetTarget = "netstandard2.0"
} catch {
    $dotNetTarget = "Net40-client"
}

$AssembliesToLoad = Get-ChildItem -Path "$PSScriptRoot\lib\$dotNetTarget\*.dll" -ErrorAction SilentlyContinue
if ($AssembliesToLoad) {
    #If we are in a build or a pester test, load assemblies from a temporary file so they don't lock the original file
    #This helps to prevent cleaning problems due to a powershell session locking the file because unloading a module doesn't unload assemblies
    if ($BuildTask -or $TestDrive) {
        Write-Verbose "Detected Invoke-Build or Pester, loading assemblies from a temp location to avoid locking issues"
        if ($Global:BuildAssembliesLoadedPreviously) {
            Write-Warning "You are in a build or test environment. We detected that module assemblies were loaded in this same session on a previous build or test. Strongly recommend you kill the process and start a new session for a clean build/test!"
        }

        $TempAssembliesToLoad = @()
        foreach ($AssemblyPathItem in $AssembliesToLoad) {
            $TempAssemblyPath = [System.IO.Path]::GetTempFileName() + ".dll"
            Copy-Item $AssemblyPathItem $TempAssemblyPath
            $TempAssembliesToLoad += [System.IO.FileInfo]$TempAssemblyPath
        }
        $AssembliesToLoad = $TempAssembliesToLoad
        $Global:BuildAssembliesLoadedPreviously = $true
    }

    Write-Verbose "Loading Assemblies for .NET target: $dotNetTarget"
    Add-Type -Path $AssembliesToLoad.FullName -ErrorAction Stop
} else {
    Write-Error "No assemblies found for .NET target: $dotNetTarget"
}

#Dot source the files
Foreach($FunctionToImport in @($PublicFunctions + $PrivateFunctions))
{
    Try
    {
        . $FunctionToImport.FullName
    }
    Catch
    {
        Write-Error -Message "Failed to import function $($import.FullName): $_"
    }
}

#Import Settings files as global objects based on their filename
foreach ($ModuleSettingsItem in $ModuleSettings)
{
    New-Variable -Name "$($ModuleSettingsItem.BaseName)" -Scope Global -Value (ConvertFrom-Json (Get-Content -Raw $ModuleSettingsItem.FullName)) -Force
}

#Export the public functions. This requires them to match the standard Noun-Verb powershell cmdlet format as a safety mechanism
Export-ModuleMember -Function ($PublicFunctions.Basename | Where-Object {$PSitem -match '^\w+-\w+$'})