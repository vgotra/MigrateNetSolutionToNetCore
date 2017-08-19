Param([string]$startDirectory = "", [bool]$isVerbose = $false)

if (($startDirectory -eq "") -or (!(Test-Path $startDirectory))){
    Write-Host "Please specify valid start directory" -ForegroundColor Red
    return
}

$backupFolder = "migration_backups"
$alreadyMigrated = "project.migrated.txt" # used for indicating that project already migrated (if we have few solutions with one and the same project)
$removeVsUserSettings = $true # will remove .vs folder, *.suo and *.user files
$removeBackupsAfterMigration = $false # if you have source repository - it safe to remove old files 

$ProjectCommonSettings = New-Object PSObject -Property @{
    GenerateAssemblyInfo               = $false;
    AutoGenerateBindingRedirects       = $true;
    GenerateBindingRedirectsOutputType = $true;
}

$LocalNugetServers = @(
    
    # New-Object PSObject -Property @{
    #     Id       = "";
    #     Url      = "";
    #     Username = "";
    #     Password = ""
    # }
)

function Generate-Project-Common-Settings {
    $propertyGroups = @("<PropertyGroup>")

    if (!($ProjectCommonSettings.GenerateAssemblyInfo)) {
        $propertyGroups += ("<GenerateAssemblyInfo>false</GenerateAssemblyInfo>")
    }

    if ($ProjectCommonSettings.AutoGenerateBindingRedirects) {
        $propertyGroups += ("<AutoGenerateBindingRedirects>true</AutoGenerateBindingRedirects>")
    }

    if ($ProjectCommonSettings.GenerateBindingRedirectsOutputType) {
        $propertyGroups += ("<GenerateBindingRedirectsOutputType>true</GenerateBindingRedirectsOutputType>")
    } 

    $propertyGroups += ("</PropertyGroup>")

    return $propertyGroups -join "`r`n" | Out-String
}

function Create-Local-Nuget-Config($folder) {
    $nugetConfigFile = Join-Path $folder "Nuget.config"

    if (Test-Path $nugetConfigFile) {
        # return false as indicator that Nuget.config should not be deleted later
        return $false
    }

    $packageSources = @()

    foreach ($server in $LocalNugetServers) {
        $packageSources += "<add key=`"$($server.Id)`" value=`"$($server.Url)`" />"
    }

    $packageCredentials = @()

    foreach ($server in $LocalNugetServers) {
        $pass = [Security.SecurityElement]::Escape($server.Password)
        $packageCredentials += ("<$($server.Id)>")
        $packageCredentials += ("<add key=`"Username`" value=`"$($server.Username)`" />")
        $packageCredentials += ("<add key=`"ClearTextPassword`" value=`"$pass`" />")
        $packageCredentials += ("</$($server.Id)>")
    }

    $nugetConfigContent = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
    <packageSources>
        $($packageSources -join "`r`n" | Out-String)
    </packageSources>
    <packageSourceCredentials>
        $($packageCredentials -join "`r`n" | Out-String)
    </packageSourceCredentials>
</configuration>
"@

    Set-Content $nugetConfigFile $nugetConfigContent

    # return true as indicator that Nuget.config should be deleted later
    return $true
}

function Delete-Local-Nuget-Config($folder, $shouldBeDeleted) {
    $nugetConfigFile = Join-Path $folder "Nuget.config"

    if (!(Test-Path $nugetConfigFile)) {
        return 
    }

    if (!($shouldBeDeleted)) {
        return
    }

    Remove-Item $nugetConfigFile
}

function Write-Collection-Verbose($title, $collection) {
    if ($isVerbose) {
        Write-Host "`n$title : " -ForegroundColor Green
        foreach ($item in $collection) {
            Write-Output $item 
        }
    }
}

function Write-Object-Verbose($title, $obj) {
    if ($isVerbose) {
        Write-Host "`n$title : " -ForegroundColor Green
        Write-Host $obj
    }
}

function Get-NetCore-Project-Type($guidTypes, $outputType) {
    # at current moment - only classlib - without asp.net core to start from general compatibility

    $mappings = @{
        #web
        "8BB2217D-0F2D-49D1-97BC-3654ED321F3B" = "web";
        #mvc
        "603C0E0B-DB56-11DC-BE95-000D561079B0" = "mvc";
        "F85E285D-A4E0-4152-9332-AB1D724D3325" = "mvc";
        "E53F8FEA-EAE0-44A6-8774-FFD645390401" = "mvc";
        "E3E379DF-F4C6-4180-9B81-6769533ABE47" = "mvc";
        "349C5851-65DF-11DA-9384-00065B846F21" = "mvc";
        #mstest
        "3AC096D0-A1C2-E12C-1390-A8335801FDAB" = "mstest";
        #class
        "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC" = "classlib"
    }

    return "classlib"
}

function Remove-Bin-Obj-Folders($projectDir) {
    $binPath = Join-Path $projectDir "bin"
    $objPath = Join-Path $projectDir "obj"
    
    if (Test-Path $binPath) {
        Remove-Item -Path $binPath -Recurse -Force
    }
    
    if (Test-Path $objPath) {
        Remove-Item -Path $objPath -Recurse -Force
    }
}

function Is-NetCore-Installed {
    return ((Test-Path 'C:\Program Files\dotnet\sdk') -or (Test-Path 'C:\Program Files (x86)\dotnet\sdk'))
}

function Is-SqlClient-Usage-Detected($projectDir) {
    if (!(Test-Path $projectDir)) {
        return $false
    }

    $csFiles = Get-ChildItem $projectDir -Include *.cs -File -Recurse
    
    foreach ($csFile in $csFiles) {
        $content = Get-Content -Path $csFile
        if ($content -like "*using System.Data.SqlClient;*") {
            return $true
        }
    }

    return $false    
}

function Get-Solution-Projects($solutionPath) {
    if (!(Test-Path $solutionPath)) {
        return @()
    }

    $projects = Get-Content $solutionPath | Select-String '^Project\("{(.+)}"\) = "(.+)", "(.+\.csproj)", "{(.+)}"$' | ForEach-Object {
        $projectParts = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Type = $projectParts[1].Value;
            Name = $projectParts[2].Value;
            File = $projectParts[3].Value;
            Guid = $projectParts[4].Value;
        }
    }

    return $projects
}

function Get-Project-Bond-Codegen-Items($projectPath) {
    # for Microsoft Bond - https://github.com/Microsoft/bond
    if (!(Test-Path $projectPath)) {
        return @()
    }

    $bondItems = Get-Content $projectPath | Select-String '^.*<BondCodegen Include="(.+\.bond)" *\/?>$' | ForEach-Object {
        $items = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Id = $items[1].Value;
        }
    }

    return $bondItems
}

function Get-Project-System-References($projectPath) {
    if (!(Test-Path $projectPath)) {
        return @()
    }

    $references = Get-Content $projectPath | Select-String '^.*<Reference Include="(.+)" *\/?>$' | ForEach-Object {
        $refs = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Name = $refs[1].Value;
        }
    }

    return $references
}

function Get-Project-System-References($projectPath) {
    if (!(Test-Path $projectPath)) {
        return @()
    }

    $references = Get-Content $projectPath | Select-String '^.*<Reference Include="(.+)" *\/?>$' | ForEach-Object {
        $refs = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Name = $refs[1].Value;
        }
    }

    return $references
}

function Get-Project-NonSystem-References($projectPath) {
    if (!(Test-Path $projectPath)) {
        return @()
    }

    $fc = Get-Content $projectPath -Raw
    $matches = $fc | Select-String '(?mi).*<Reference Include="(.*)" *\/?>[\r\n]*.*<HintPath>(.+.dll)<\/HintPath>[\r\n]*.*<\/Reference>' -AllMatches

    if (!($matches.Matches)) {
        return @()
    }

    $nonSystemRefs = $matches.Matches | Where-Object { $_.Value -notlike "*, Version=*" }
    $references = $nonSystemRefs | ForEach-Object {
        $refs = $_.Groups

        New-Object PSObject -Property @{
            Name     = $refs[1].Value;
            HintPath = $refs[2].Value;
        }
    }

    return $references
}

function Remove-Nuget-From-NonSystem-References($projectNonSystemReferences, $projectPackages) {
    $result = @()

    Write-Collection-Verbose "Input NonSystem References" $projectNonSystemReferences
    Write-Collection-Verbose "Project Packages" $projectPackages
    
    foreach ($nonSystemRef in $projectNonSystemReferences) {
        $found = $false
        foreach ($projPkg in $projectPackages) {
            if ($projPkg.Id -eq $nonSystemRef.Name) {
                $found = $true
                break
            }
        }
        if (!($found)) {
            $result += ($nonSystemRef)
        }
    }

    Write-Collection-Verbose "Filtered NonSystem References" $result

    return $result
}

function Get-Project-Packages($packagesPath) {
    if (!(Test-Path $packagesPath)) {
        return @()
    }

    $packages = Get-Content $packagesPath | Select-String '^.*<package id="(.+)" version="(.+)" targetFramework="(.+)" *\/?>$' | ForEach-Object {
        $packageParts = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Id              = $packageParts[1].Value;
            Version         = $packageParts[2].Value;
            TargetFramework = $packageParts[3].Value;
        }
    }

    return $packages
}

function Get-Project-References($projectPath) {
    $projects = Get-Content $projectPath | Select-String '^.*<ProjectReference Include="(.+)" *\/?>$' | ForEach-Object {
        $projectRefsParts = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Path = $projectRefsParts[1].Value;
        }
    }

    return $projects
}

function Substitute-System-References-By-Nuget-Packages($projectDir, $projectReferences, $projectPackages) {
    if (!(Test-Path $projectDir)) {
        return @()
    }

    # sometimes we can use only Common instead of SqlClient Nuget package
    $nugetDataPackage = "System.Data.Common"
    if (Is-SqlClient-Usage-Detected $projectDir) {
        $nugetDataPackage = "System.Data.SqlClient"
    }

    $mappings = @{
        "System.Configuration"                  = "System.Configuration.ConfigurationManager";
        "System.Data"                           = $nugetDataPackage;
        "System.ComponentModel.DataAnnotations" = "System.ComponentModel.Annotations";
    }

    Write-Collection-Verbose "Project references" $projectReferences
    Write-Collection-Verbose "Project packages" $projectPackages

    # add missing project packages    
    foreach ($projectRef in $projectReferences) {
        if ($mappings.ContainsKey("$($projectRef.Name)")) {
            $item = New-Object PSObject -Property @{
                Id              = $mappings.Get_Item("$($projectRef.Name)");
                Version         = "";
                TargetFramework = "";
            }

            $found = $false

            foreach ($projectPkg in $projectPackages) {
                if ($projectPkg.Id -eq $item.Id) {
                    $found = $true
                    break
                }
            }

            if (!($found)) {
                $projectPackages = [Array]$projectPackages + $item
            }
        }
    }

    Write-Collection-Verbose "Filtered project packages" $projectPackages

    return $projectPackages
}

function Move-NetCore-Project-Sources($pathToSources) {
    $parentFolder = $pathToSources | Split-Path
    Remove-Item (Join-Path $pathToSources "Class1.cs") 
    Get-ChildItem $pathToSources | Move-Item -Destination $parentFolder -Force
    Remove-Item $pathToSources -Recurse
}

function Add-Common-Properties-To-Project($projectPath) {
    [xml]$properties = Generate-Project-Common-Settings

    $xml = [xml](Get-Content $projectPath)

    $xml.Project.AppendChild($xml.ImportNode($properties.PropertyGroup, $true))
    $xml.Save($projectPath)
}

function Add-Bond-Items-To-Project($projectPath, $bondItems) {
    if (!(Test-Path $projectPath)) {
        return
    }

    if (!($bondItems)) {
        return
    }

    $itemGroups = @("<ItemGroup>")
    
    foreach ($bondItem in $bondItems) {
        $itemGroups += ("<BondCodegen Include=`"$($bondItem.Id)`" />")
    }
    
    $itemGroups += ("</ItemGroup>")

    $xmlBondItems = [xml]($itemGroups -join "`r`n" | Out-String)

    $xml = [xml](Get-Content $projectPath)

    $xml.Project.AppendChild($xml.ImportNode($xmlBondItems.ItemGroup, $true))
    $xml.Save($projectPath)
}

function Add-NonSystem-References-To-Project($projectPath, $projectNonSystemReferences) {
    if (!(Test-Path $projectPath)) {
        return
    }

    if (!($projectNonSystemReferences)) {
        return
    }

    $itemGroups = @("<ItemGroup>")
    
    foreach ($projectNonSystemRef in $projectNonSystemReferences) {
        $ref = @"
<Reference Include=`"$($projectNonSystemRef.Name)`">
    <HintPath>$($projectNonSystemRef.HintPath)</HintPath>
</Reference>
"@
        $itemGroups += ($ref)
    }
    
    $itemGroups += ("</ItemGroup>")

    [xml]$nonSysRefs = ($itemGroups -join "`r`n" | Out-String)

    $xml = [xml](Get-Content $projectPath)

    $xml.Project.AppendChild($xml.ImportNode($nonSysRefs.ItemGroup, $true))
    $xml.Save($projectPath)
}

function Migrate-Project-To-NetCore($solutionDir, $project) {
    # get build configuration ?
    # get pre/post build 
    # what to do with designer files / DependentUpon?
    # what to do with other targets ? - also - None Include ?

    $projectPath = Join-Path $solutionDir $project.File
    $projectDirPath = $projectPath | Split-Path
    $projectMigratedIndicator = Join-Path $projectDirPath $alreadyMigrated

    # if already migrated - continue
    if (Test-Path $projectMigratedIndicator) {
        return
    }
    
    $oldLocation = Get-Location
    Set-Location $projectDirPath

    # create according to project type and output
    Write-Host "Started migrating project: $($project.File)" -ForegroundColor Green
    
    $shouldDeleteNugetConfig = $false

    if ($LocalNugetServers.Length -gt 0) {
        # create local nuget 
        $shouldDeleteNugetConfig = Create-Local-Nuget-Config $projectDirPath
    }

    # get output type for .Net Core prj type
    $prjType = Get-NetCore-Project-Type $project

    $projectPackagesPath = Join-Path $projectDirPath "packages.config"
    $projectPackages = Get-Project-Packages $projectPackagesPath
    $projectReferences = Get-Project-System-References $projectPath
    $projectPackages = Substitute-System-References-By-Nuget-Packages $projectDirPath $projectReferences $projectPackages
    $projectNonSystemReferences = Get-Project-NonSystem-References $projectPath
    $filteredNonSystemReferences = Remove-Nuget-From-NonSystem-References $projectNonSystemReferences $projectPackages

    $bondItems = Get-Project-Bond-Codegen-Items $projectPath

    $backupPath = Join-Path $projectDirPath $backupFolder
    
    #backup project
    if (!(Test-Path $backupPath)) {
        mkdir $backupPath
    }

    if (Test-Path $projectPackagesPath) {
        Write-Host "Moving old packages.config file to backup folder" -ForegroundColor Yellow
        Move-Item $projectPackagesPath $backupPath
    }

    Write-Host "Moving old project file to backup folder" -ForegroundColor Yellow
    Move-Item $projectPath $backupPath

    Remove-Bin-Obj-Folders $projectDirPath

    Write-Host "Create new NetCore project with name: $($project.Name)" -ForegroundColor Green

    # create new project
    dotnet new $prjType -n $project.Name

    Set-Content $projectMigratedIndicator ""

    Move-NetCore-Project-Sources (Join-Path $projectDirPath $project.Name)

    # add common properies for project
    Add-Common-Properties-To-Project $projectPath
    Add-Bond-Items-To-Project $projectPath $bondItems

    Add-NonSystem-References-To-Project $projectPath $filteredNonSystemReferences

    foreach ($projectPackage in $projectPackages) {
        if ($projectPackage.Version -eq "") {
            dotnet add package $projectPackage.Id     
        }
        else {
            dotnet add package $projectPackage.Id -v $projectPackage.Version
        }
    }

    Delete-Local-Nuget-Config $projectDirPath $shouldDeleteNugetConfig

    Set-Location $oldLocation 
}

function Restore-Project-References($solutionDir, $project) {
    $projectPath = Join-Path $solutionDir $project.File
    $projectDirPath = $projectPath | Split-Path
    $projectName = $projectPath | Split-Path -Leaf
    $projectBackupPath = Join-Path (Join-Path $projectDirPath $backupFolder) $projectName
    
    $projectReferences = Get-Project-References $projectBackupPath

    $oldLocation = Get-Location
    Set-Location $projectDirPath

    foreach ($projectRef in $projectReferences) {
        dotnet add $projectName reference $projectRef.Path
    }

    Set-Location $oldLocation 
}

function Migrate-Solution-To-NetCore($solution) {
    Write-Host "Migrating solution file: $solution" -ForegroundColor Green

    $solutionDir = $solution | Split-Path 
    $oldLocation = Get-Location
    Set-Location $solutionDir

    Write-Host "Solution directory: $solutionDir" -ForegroundColor Green

    $projects = Get-Solution-Projects $solution
    
    Write-Collection-Verbose "Projects in Solution" $projects

    $backupPath = Join-Path $solutionDir $backupFolder

    #backup solution
    if (!(Test-Path $backupPath)) {
        mkdir $backupPath
    }

    Write-Host "Moving old solution file to backup folder" -ForegroundColor Yellow
    Move-Item $solution $backupPath

    $solutionName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $solution -leaf))

    Write-Host "Create new NetCore solution with name: $solutionName" -ForegroundColor Green

    # create empty solution 
    dotnet new sln -n $solutionName

    # add nuget packages
    foreach ($project in $projects) {
        Migrate-Project-To-NetCore $solutionDir $project

        # add project to solution
        $projectPath = Join-Path $solutionDir $project.File
        dotnet sln $solution add $projectPath
    }
    
    Set-Location $oldLocation
}

function Add-Project-References-To-Migrated-Projects($solution) {
    Write-Host "Adding references to migrated projects for solution file: $solution" -ForegroundColor Green

    $solutionDir = $solution | Split-Path 
    $oldLocation = Get-Location
    Set-Location $solutionDir

    Write-Host "Solution directory: $solutionDir" -ForegroundColor Green

    $projects = Get-Solution-Projects $solution
    
    Write-Collection-Verbose "Projects in Solution" $projects

    # add project references
    foreach ($project in $projects) {
        Restore-Project-References $solutionDir $project
    }
    
    Set-Location $oldLocation
}

function Rollback-All-Changes($rootPath) {
    if ($removeVsUserSettings) {
        Write-Host "Removing .suo, .user, .vs folders before migration" -ForegroundColor Yellow

        Get-ChildItem $rootPath -Filter *.suo -File -Recurse | % { $_.FullName } |  Remove-Item -Force
        Get-ChildItem $rootPath -Filter *.user -File -Recurse | % { $_.FullName } |  Remove-Item -Force
        Get-ChildItem $rootPath -Filter .vz -Directory -Recurse | % { $_.FullName } |  Remove-Item -Force -Recurse
    }

    Write-Host "Restoring backup files before migration" -ForegroundColor Yellow
    # iterate throught all backup folders and move back all backup solution, project and other files
    $backupPaths = Get-ChildItem $rootPath -Filter $backupFolder -Recurse -Directory | % { $_.FullName }

    Write-Collection-Verbose "Backup Paths" $backupPaths

    foreach ($backupPath in $backupPaths) {
        $parentBackupPath = $backupPath | Split-Path
        
        Get-ChildItem $backupPath | Move-Item -Destination $parentBackupPath -Force

        Remove-Item $backupPath
    }

    Write-Host "Removing $alreadyMigrated files before migration" -ForegroundColor Yellow
    Get-ChildItem $rootPath -Filter $alreadyMigrated -Recurse | % { $_.FullName } |  Remove-Item
}

function Migrate-To-NetCore($rootPath) {
    if (!(Is-NetCore-Installed)) {
        Write-Host ".Net Core SDK is not installed" -ForegroundColor Red
        return
    }

    if (!(Test-Path $rootPath)) {
        Write-Host "Path $rootPath doesn't exist" -ForegroundColor Red
        return
    }

    $solutionsPaths = Get-ChildItem $rootPath -Filter *.sln -Exclude "*$backupFolder*" -Recurse | % { $_.FullName }

    Write-Collection-Verbose "Solutions Paths" $solutionsPaths

    # create full structure of .NetCore
    foreach ($solution in $solutionsPaths) {
        Migrate-Solution-To-NetCore $solution
    }

    # iterate all projects backups to add references between projects
    foreach ($solution in $solutionsPaths) {
        Add-Project-References-To-Migrated-Projects $solution
    }

    Write-Host "Removing $alreadyMigrated files before migration" -ForegroundColor Yellow
    # remove migration indicators
    Get-ChildItem $rootPath -Filter $alreadyMigrated -Recurse | % { $_.FullName } |  Remove-Item

    if ($removeBackupsAfterMigration) {
        Write-Host "Removing backup folders after migration" -ForegroundColor Yellow
        Get-ChildItem $rootPath -Filter $backupFolder -Directory -Recurse | % { $_.FullName } |  Remove-Item -Force -Recurse
    }
}

$oldLocation = Get-Location

Rollback-All-Changes $startDirectory

try {
    Migrate-To-NetCore $startDirectory
}
catch {
    Write-Host ("Error: " + $_.Exception.ToString()) -ForegroundColor Red
    
    # rollback all changes
    Rollback-All-Changes $startDirectory

    Set-Location $oldLocation
}
