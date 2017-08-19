# MigrateNetSolutionToNetCore
PowerShell script for partial migration of .Net Framework solution (except unsupported - WPF/Windows Forms, etc) to .Net Core solution for checking compatibility
Notes: ONLY for TEST usage for checking problems during migration to .Net Core

## Usage:
``` cmd
.\MigrateNetSolutionToNetCore.ps1 -startDirectory "C:\Path"
```

## Prerequisites for currect work:
- latest .Net Core SDK Standard 2 - https://www.microsoft.com/net/core/preview#windowscmd
- in case of local Nuget repository - valid Nuget settings or Nuget configuration to avoid creation of Nuget.config for every project 

## What is working:
- Local Nuget configuration
- Removing old bin/obj/.vs/etc before migration for easy clean build
- Backups of old solution/project/packages files
- Automatic adding of existing Nuget packages 
- Adding of some references specified in project files
- Reusing of assembly info from existing projects (GenerateAssemblyInfo)
- Support for Microsoft Bond codegen targets
- Partial substitution of system references and some old Nuget packages by compatible with .Net Core Standard 2 Nuget packages - System.ConfigurationManager, etc.

## Not working/Still in process/Notes:
- Pre/Post build events is not implemented
- Updating Nuget packages to the **pre** versions is not ready (waiting for dotnet cli implementation for that feature)
- Build configurations - only default build configurations are supported
- Migration of different targets
- Choosing right type of project (classlib/web/etc) - at current momment only classlib is supported

## Nuget settings:
- if you have local Nuget repository - please setup your Nuget configuration in script
Example: 
``` powershell
$LocalNugetServers = @(
    
    New-Object PSObject -Property @{
        Id       = "Test";
        Url      = "http://test.local/httpAuth/app/nuget/v1/FeedService.svc/";
        Username = "test\testuser";
        Password = "testpass"
    }
) 
```
