$isVerbose = $false # $VerbosePreference -ne 'SilentlyContinue'
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

function Migrate-To-Net-Core-Solution($solution){
    Write-Host "Migrating solution file: $solution" -ForegroundColor Green

    $solutionDir = $solution | Split-Path
    Set-Location $solutionDir

    Write-Host "Solution directory: $solutionDir" -ForegroundColor Green

    $projects = Get-Solution-Projects $solution
    
    Write-Collection-Verbose "Projects in Solution" $projects

    $backupPath = "$solutionDir\backup"

    #backup solution
    if (!(Test-Path $backupPath)){
        mkdir "$solutionDir\backup"
    }

    Write-Host "Moving old solution file to backup folder" -ForegroundColor Yellow
    Move-Item $solution "$solutionDir\backup"

    $solutionName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $solution -leaf))

    Write-Host "Create new NetCore solution with name: $solutionName" -ForegroundColor Green
    
    Write-Object-Verbose "Current location" Get-Location

    # create empty solution 
    dotnet new sln -n $solutionName
}

function Migrate-To-Net-Core-Project(){
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
        Migrate-To-Net-Core-Solution $solution
    }
}

#Rollback-All-Changes C:\Temp\solution

try {
    Migrate-To-Net-Core C:\Temp\solution
}
catch {
    # rollback all changes
    Rollback-All-Changes C:\Temp\solution
}
