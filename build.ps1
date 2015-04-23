param(
    $task = "default"
)

get-module psake | remove-module

.\src\.nuget\NuGet.exe install ".\src\.nuget\packages.config" -OutputDirectory ".\src\packages"

Import-Module (Get-ChildItem ".\src\packages\psake.*\tools\psake.psm1" | Select-Object -First 1)

Import-Module .\IO.psm1
Import-Module .\teamcity.psm1

Invoke-Psake .\default.ps1 $task -framework "4.0x64"

Remove-Module teamcity
Remove-Module psake
Remove-Module IO