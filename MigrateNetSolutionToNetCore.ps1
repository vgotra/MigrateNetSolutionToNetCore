$isVerbose = $false # $VerbosePreference -ne 'SilentlyContinue'
$backupFolder = "migration_backups"
$alreadyMigrated = "project.migrated.txt"
$startDirectory = "c:\Projects"

$ProjectCommonSettings = New-Object PSObject -Property @{
        GenerateAssemblyInfo = $false;
}

$LocalNugetServers = @(
    
    # New-Object PSObject -Property @{
    #     Id = "";
    #     Url = "";
    #     Username = "";
    #     Password = ""
    # }
)

function Write-Collection-Verbose($title, $collection){
    if ($isVerbose) {
        Write-Host "`n$title : " -ForegroundColor Green
        foreach ($item in $collection){
            Write-Output $item 
        }
    }
}

function Write-Object-Verbose($title, $obj){
    if ($isVerbose) {
        Write-Host "`n$title : " -ForegroundColor Green
        Write-Host $obj
    }
}

function Get-NetCore-Project-Type($guidTypes, $outputType){
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

function Is-NetCore-Installed {
    return ((Test-Path 'C:\Program Files\dotnet\sdk') -or (Test-Path 'C:\Program Files (x86)\dotnet\sdk'))
}

function Get-Solution-Projects($solution){
    $projects = Get-Content $solution | Select-String '^Project\("{(.+)}"\) = "(.+)", "(.+\.csproj)", "{(.+)}"$' | ForEach-Object {
        $projectParts = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Type = $projectParts[1];
            Name = $projectParts[2];
            File = $projectParts[3];
            Guid = $projectParts[4]
        }
    }

    return $projects
}

function Get-Project-Packages($packagePath){
    if (!(Test-Path $packagePath)){
        return @()
    }

    $packages = Get-Content $packagePath | Select-String '^.+<package id="(.+)" version="(.+)" targetFramework="(.+)" \/>$' | ForEach-Object {
        $projectParts = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Id = $projectParts[1];
            Version = $projectParts[2];
            TargetFramework = $projectParts[3];
        }
    }

    return $packages
}

function Remove-Bin-Obj-Folders($path){
    $binPath = Join-Path $path "bin"
    $objPath = Join-Path $path "obj"
    
    if (Test-Path $binPath){
        Remove-Item -Path $binPath -Recurse -Force
    }
    
    if (Test-Path $objPath){
        Remove-Item -Path $objPath -Recurse -Force
    }
}

function Get-Project-Common-Settings{
    $propertyGroups = @("<PropertyGroup>")

    if(!($ProjectCommonSettings.GenerateAssemblyInfo)){
        $propertyGroups += ("<GenerateAssemblyInfo>false</GenerateAssemblyInfo>")
    }
    
    $propertyGroups += ("</PropertyGroup>")

    return $propertyGroups -join "`r`n" | Out-String
}

function Create-Local-Nuget-Config($folder){
    # TODO: check for existing Nuget.config
    $nugetConfigFile = Join-Path $folder "Nuget.config"

    if (Test-Path $nugetConfigFile){
        # return false as indicator that Nuget.config should not be deleted later
        return $false
    }

    $packageSources = @()

    foreach ($server in $LocalNugetServers){
        $packageSources += "<add key=`"$($server.Id)`" value=`"$($server.Url)`" />"
    }

    $packageCredentials = @()

    foreach ($server in $LocalNugetServers){
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

function Delete-Local-Nuget-Config($folder, $shouldBeDeleted){
    $nugetConfigFile = Join-Path $folder "Nuget.config"

    if (!(Test-Path $nugetConfigFile)){
        return 
    }

    if(!($shouldBeDeleted)){
        return
    }

    Remove-Item $nugetConfigFile
}

function Move-NetCore-Project-Sources($pathToSources){
    $parentFolder = $pathToSources | Split-Path
    Remove-Item (Join-Path $pathToSources "Class1.cs") 
    Get-ChildItem $pathToSources | Move-Item -Destination $parentFolder -Force
    Remove-Item $pathToSources -Recurse
}

function Add-Common-Properties-To-Project($projectPath){
    [xml]$properties = Get-Project-Common-Settings

    $xml = [xml](Get-Content $projectPath)

    $xml.Project.AppendChild($xml.ImportNode($properties.PropertyGroup, $true))
    $xml.Save($projectPath)
}

function Migrate-Project-To-NetCore($solutionDir, $project){
    # get build configuration ?
    # get pre/post build 
    # what to do with designer files / DependentUpon?
    # what to do with other targets ? - also - None Include ?

    $projectPath = Join-Path $solutionDir $project.File
    $projectDirPath = $projectPath | Split-Path
    $projectMigratedIndicator = Join-Path $projectDirPath $alreadyMigrated

    # if already migrated - continue
    if (Test-Path $projectMigratedIndicator){
        return
    }
    
    $oldLocation = Get-Location
    Set-Location $projectDirPath

    # create according to project type and output
    Write-Host "Started migrating project: $($project.File)" -ForegroundColor Green
    
    $shouldDeleteNugetConfig = $false

    if ($LocalNugetServers.Length -gt 0){
        # create local nuget 
        $shouldDeleteNugetConfig = Create-Local-Nuget-Config $projectDirPath
    }

    # get output type for .Net Core prj type
    $prjType = Get-NetCore-Project-Type $project

    $backupPath = Join-Path $projectDirPath $backupFolder

    #backup solution
    if (!(Test-Path $backupPath)){
        mkdir $backupPath
    }

    $projectPackagesPath = Join-Path $projectDirPath "packages.config"
    $projectPackages = Get-Project-Packages $projectPackagesPath

    if (Test-Path $projectPackagesPath){
        Write-Host "Moving old packages.config file to backup folder" -ForegroundColor Yellow
        Move-Item $projectPackagesPath $backupPath
    }

    Write-Host "Moving old project file to backup folder" -ForegroundColor Yellow
    Move-Item $projectPath $backupPath

    Write-Host "Create new NetCore project with name: $($project.Name)" -ForegroundColor Green

    Remove-Bin-Obj-Folders $projectDirPath

    # create empty solution 
    dotnet new $prjType -n $project.Name

    Set-Content $projectMigratedIndicator ""

    Move-NetCore-Project-Sources (Join-Path $projectDirPath $project.Name)

    # add common properies for project
    Add-Common-Properties-To-Project $projectPath

    foreach ($projectPackage in $projectPackages){
        dotnet add package $projectPackage.Id
    }

    Delete-Local-Nuget-Config $projectDirPath $shouldDeleteNugetConfig

    Set-Location $oldLocation 
}

function Get-Project-References($projectPath){
    $projects = Get-Content $projectPath | Select-String '^.+<ProjectReference Include="(.+)">$' | ForEach-Object {
        $projectParts = $_.Matches[0].Groups
        New-Object PSObject -Property @{
            Path = $projectParts[1];
        }
    }

    return $projects
}

function Restore-Project-References($solutionDir, $project){
    $projectPath = Join-Path $solutionDir $project.File
    $projectDirPath = $projectPath | Split-Path
    $projectName = $projectPath | Split-Path -Leaf
    $projectBackupPath = Join-Path (Join-Path $projectDirPath $backupFolder) $projectName
    
    $projectReferences = Get-Project-References $projectBackupPath

    $oldLocation = Get-Location
    Set-Location $projectDirPath

    foreach ($projectRef in $projectReferences){
        dotnet add $projectName reference $projectRef.Path
    }

    Set-Location $oldLocation 
}

function Migrate-Solution-To-NetCore($solution){
    Write-Host "Migrating solution file: $solution" -ForegroundColor Green

    $solutionDir = $solution | Split-Path 
    $oldLocation = Get-Location
    Set-Location $solutionDir

    Write-Host "Solution directory: $solutionDir" -ForegroundColor Green

    $projects = Get-Solution-Projects $solution
    
    Write-Collection-Verbose "Projects in Solution" $projects

    $backupPath = Join-Path $solutionDir $backupFolder

    #backup solution
    if (!(Test-Path $backupPath)){
        mkdir $backupPath
    }

    Write-Host "Moving old solution file to backup folder" -ForegroundColor Yellow
    Move-Item $solution $backupPath

    $solutionName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $solution -leaf))

    Write-Host "Create new NetCore solution with name: $solutionName" -ForegroundColor Green

    # create empty solution 
    dotnet new sln -n $solutionName

    # add nuget packages
    foreach ($project in $projects){
        Migrate-Project-To-NetCore $solutionDir $project

        # add project to solution
        $projectPath = Join-Path $solutionDir $project.File
        dotnet sln $solution add $projectPath
    }
    
    Set-Location $oldLocation
}

function Add-Project-References-To-Migrated-Projects($solution){
    Write-Host "Adding references to migrated projects for solution file: $solution" -ForegroundColor Green

    $solutionDir = $solution | Split-Path 
    $oldLocation = Get-Location
    Set-Location $solutionDir

    Write-Host "Solution directory: $solutionDir" -ForegroundColor Green

    $projects = Get-Solution-Projects $solution
    
    Write-Collection-Verbose "Projects in Solution" $projects

    # add project references
    foreach ($project in $projects){
        Restore-Project-References $solutionDir $project
    }
    
    Set-Location $oldLocation
}

function Convert-Packages-To-NetCore-Format($packages){
    $pkgs = @("<ItemGroup>")

    foreach ($package in $packages){
        $pkg = "<PackageReference Include=`"$($package.Id)`" Version=`"$($package.Version)`" />"
        $pkgs += $pkg
    }
    
    $pkgs += ("<ItemGroup>")

    return $pkgs -join "`r`n" | Out-String
}

function Rollback-All-Changes($rootPath){
    # iterate throught all backup folders and move back all backup solution, project and other files
    $backupPaths = Get-ChildItem $rootPath -Filter $backupFolder -Recurse -Directory | % { $_.FullName }

    Write-Collection-Verbose "Backup Paths" $backupPaths

    foreach ($backupPath in $backupPaths){
        $parentBackupPath = $backupPath | Split-Path
        
        Get-ChildItem $backupPath | Move-Item -Destination $parentBackupPath -Force

        Remove-Item $backupPath
    }

    Get-ChildItem $rootPath -Filter $alreadyMigrated -Recurse | % { $_.FullName } |  Remove-Item
}

function Migrate-To-NetCore($rootPath) {
    if (!(Is-NetCore-Installed)){
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
    foreach ($solution in $solutionsPaths){
        Migrate-Solution-To-NetCore $solution
    }

    # iterate all projects backups to add references between projects
    foreach ($solution in $solutionsPaths){
        Add-Project-References-To-Migrated-Projects $solution
    }

    # remove migration indicators
    Get-ChildItem $rootPath -Filter $alreadyMigrated -Recurse | % { $_.FullName } |  Remove-Item
}

Rollback-All-Changes $startDirectory

try {
    Migrate-To-NetCore $startDirectory
}
catch {
    # rollback all changes
    Rollback-All-Changes $startDirectory
}
