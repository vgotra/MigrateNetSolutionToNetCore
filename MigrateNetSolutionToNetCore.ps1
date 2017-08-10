$isVerbose = $true # $VerbosePreference -ne 'SilentlyContinue'
# $migrateOnlyProjectFromSolution = $true

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

function Get-Net-Core-Project-Type($guids, $outputType){
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
        "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC" = "class"
    }

    return "class"
}

function Is-Net-Core-Installed {
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

function Migrate-Solution-To-Net-Core($solution){
    Write-Host "Migrating solution file: $solution" -ForegroundColor Green

    $solutionDir = $solution | Split-Path
    Set-Location $solutionDir

    Write-Host "Solution directory: $solutionDir" -ForegroundColor Green

    $projects = Get-Solution-Projects $solution
    
    Write-Collection-Verbose "Projects in Solution" $projects

    $backupPath = "$solutionDir\backup"

    #backup solution
    if (!(Test-Path $backupPath)){
        mkdir $backupPath
    }

    Write-Host "Moving old solution file to backup folder" -ForegroundColor Yellow
    Move-Item $solution $backupPath

    $solutionName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $solution -leaf))

    Write-Host "Create new NetCore solution with name: $solutionName" -ForegroundColor Green
    
    #Write-Object-Verbose "Current location" Get-Location

    # create empty solution 
    dotnet new sln -n $solutionName

    Migrate-Projects-To-Net-Core $solution $projects
}

function Convert-Packages-To-Net-Core-Format($packages){
    $pkgs = @("<ItemGroup>")

    foreach ($package in $packages){
        $pkg = "<PackageReference Include=`"$($package.Id)`" Version=`"$($package.Version)`" />"
        $pkgs += $pkg
    }
    
    $pkgs += ("<ItemGroup>")

    return $pkgs -join "`r`n" | Out-String
}

function Migrate-Projects-To-Net-Core($solution, $projects){

    $solutionDir = $solution | Split-Path

    foreach ($project in $projects){
        Write-Host "Started migrating project: $($project.File)" -ForegroundColor Green
        
        $projectPath = Join-Path $solutionDir $project.File
        $projectDirPath = $projectPath | Split-Path
        $projectPackagesPath = Join-Path $projectDirPath "packages.config"
        
        $projectPackages = Get-Project-Packages $projectPackagesPath
        $projectPackagesXml = Convert-Packages-To-Net-Core-Format $projectPackages

        Write-Object-Verbose "Packages" $projectPackagesXml
    }
    # get nuget packages
    # get build configuration ?
    # get project references
    # get pre/post build 
    # what to do with designer files / DependentUpon?
    # what to do with other targets ? - also - None Include ?

    # create according to project type and output
}

function Rollback-All-Changes($rootPath){
    # iterate throught all backup folders and move back all backup solution, project and other files
    $backupPaths = Get-ChildItem $rootPath -Filter backup -Recurse -Directory

    Write-Collection-Verbose "Backup Paths" $backupPaths

    foreach ($backupPath in $backupPaths){
        $parentBackupPath = $backupPath | Split-Path
        
        Get-ChildItem $backupPath.FullName | Move-Item -Destination $parentBackupPath -Force

        Remove-Item $backupPath.FullName
    }
}

function Migrate-To-Net-Core($rootPath) {
    if (!(Is-Net-Core-Installed)){
        Write-Host ".Net Core SDK is not installed" -ForegroundColor Red
        return
    }

    if (!(Test-Path $rootPath)) {
        Write-Host "Path $rootPath doesn't exist" -ForegroundColor Red
        return
    }

    $solutionsPaths = Get-ChildItem $rootPath -Filter *.sln -Recurse

    Write-Collection-Verbose "Solutions Paths" $solutionsPaths

    foreach ($solution in $solutionsPaths){
        Migrate-Solution-To-Net-Core $solution
    }
}

#Rollback-All-Changes c:\Projects

try {
    Migrate-To-Net-Core c:\Projects
}
catch {
    # rollback all changes
    Rollback-All-Changes c:\Projects
}
