properties {
    $solution           = "df-ravendb.sln"
    $test_solution      = "df-ravendb-smoketests.sln"
    $target_config      = "Release"

    $base_directory     = Resolve-Path .
    $src_directory      = "$base_directory\src"
    $output_directory   = "$base_directory\build"
    $package_directory  = "$src_directory\ravendb\packages"
    $nuget_directory    = "$src_directory\ravendb\.nuget"

    $sln_path           = "$src_directory\$solution"
    $test_sln_path      = "$src_directory\$test_solution"
    $assemblyInfo_path  = "$src_directory\GlobalAssemblyInfo.cs"
    $nuget_path         = "$nuget_directory\nuget.exe"
    $nugetConfig_path   = "$nuget_directory\nuget.config"
    $ilmerge_path       = FindTool("ILRepack.*\tools\ILRepack.exe")
    $testrunner_path    = FindTool("xunit.runner.console.*\tools\xunit.console.exe")

    $code_coverage      = $true
    $framework_version  = "v4.5"
    $build_number       = "$env:BUILD_NUMBER"
}

TaskSetup {
    $taskName = $($psake.context.Peek().currentTaskName)
    TeamCity-OpenBlock $taskName
    TeamCity-ReportBuildProgress "Running task $taskName"
}

TaskTearDown {
    $taskName = $($psake.context.Peek().currentTaskName)
    TeamCity-CloseBlock $taskName
}

task default -depends ILMerge, Test

task Init -depends Clean, VersionAssembly

task Clean {
    EnsureDirectory $output_directory

    Clean-Item $output_directory -ea SilentlyContinue

    & git submodule foreach git reset --hard

    exec { msbuild /nologo /verbosity:q $sln_path /p:"Configuration=$target_config;TargetFrameworkVersion=$framework_version" /t:clean  }
}

task VersionAssembly {
    $version = Get-Version

    if ($version) {
        Write-Output $version

        $assembly_information = "
    [assembly: System.Reflection.AssemblyVersion(""$($version.AssemblySemVer)"")]
    [assembly: System.Reflection.AssemblyFileVersion(""$($version.AssemblyFileSemVer)"")]
    [assembly: System.Reflection.AssemblyInformationalVersion(""$($version.InformationalVersion)"")]
    ".Trim()

        Write-Output $assembly_information > $assemblyInfo_path
    } else {
        Write-Output "Warning: could not get assembly information."

        Write-Output "" > $assemblyInfo_path
    }
}


task RestoreNuget {
    Get-SolutionPackages |% {
        "Restoring " + $_
        &$nuget_path install $_ -o $package_directory -configfile $nugetConfig_path
    }
}

task MungeDependencies -depends MungePatches, MungeFody {

}

task MungeFody -depends Clean {
        Write-Output "
    <Weavers>
  <Costura IncludeDebugSymbols='false'>
    <IncludeAssemblies>
        Lucene.Net
        Lucene.Net.Contrib.Spatial.NTS
    </IncludeAssemblies>
  </Costura>
</Weavers>
    ".Trim() > "$src_directory\ravendb\Raven.Database\FodyWeavers.xml"

    Write-Output "
    <Weavers>
  <Costura IncludeDebugSymbols='false'>
    <IncludeAssemblies>
    </IncludeAssemblies>
  </Costura>
</Weavers>
    ".Trim() > "$src_directory\ravendb\Raven.Client.Lightweight\FodyWeavers.xml"

    $fody_targets_path = "$src_directory\ravendb\Imports\Fody\Fody.targets"

    $fody_targets = [xml](Get-Content $fody_targets_path)

    $msbuild_ns = @{msbuild='http://schemas.microsoft.com/developer/msbuild/2003'}

    Select-Xml -Xml $fody_targets -Namespace $msbuild_ns -Xpath '//msbuild:FodyPath' | % {
        $_.Node.InnerText = "$src_directory\ravendb\SharedLibs\Fody"
    }

    Select-Xml -Xml $fody_targets -Namespace $msbuild_ns -XPath '//msbuild:Target[@Name="CleanReferenceCopyLocalPaths"]' | % {
        $_.Node.InnerText = ''
    }

    $fody_targets.Save($fody_targets_path)
}

task MungePatches -depends Clean {
    Push-Location

    cd "$src_directory\ravendb"

    & git remote add thefringeninja git@github.com:thefringeninja/ravendb.git

    & git fetch thefringeninja

    & git cherry-pick 1d77d99d9d --no-commit

    Pop-Location

}

task Compile -depends Clean, RestoreNuget, MungeDependencies {
    exec { msbuild /nologo /verbosity:q $sln_path /p:"Configuration=$target_config;TargetFrameworkVersion=$framework_version;OutDir=$output_directory"  }
}

task Test {
    exec { msbuild /nologo /verbosity:q $test_sln_path /p:"Configuration=$target_config;TargetFrameworkVersion=$framework_version;OutDir=$output_directory" /t:Rebuild  }
    RunTest -test_project "Raven.SmokeTests"
}

Task ILMerge -depends Compile {
    $merge = @(
        "ICSharpCode.*",
        "Mono.*"
    )

    ILMerge -target "Raven.Abstractions" -merge $merge
    
    Copy-Item "$output_directory\Raven.Abstractions\Raven.Abstractions.*" $output_directory

    $merge = @(
        "System.Reactive.Core",
        "System.Reactive.Interfaces"
    )

    ILMerge -target "Raven.Client.Lightweight" -merge $merge

    Copy-Item "$output_directory\Raven.Client.Lightweight\Raven.Client.Lightweight.*" $output_directory

    $merge = @(
        "System.Reactive.*",
        "System.Net.Http.Formatting",
        "System.Web.Http",
        "System.Web.Http.Owin",
        "Esent.Interop",
        "HtmlAgilityPack",
        "ICSharpCode.*",
        "Jint",
        "metrics",
        "Microsoft.Owin",
        "Microsoft.Owin.*",
        "Mono.*",
        "Owin",
        "Newtonsoft.Json",
        "Voron",
        "Lucene.Net.Contrib.Spatial.NTS",
        "Spatial4n.Core.NTS",
        "NetTopologySuite",
        "PowerCollections",
        "GeoAPI"
    )

    ILMerge -target "Raven.Database" -merge $merge
}

task Package -depends ILMerge {
    $version = Get-Version

    if ($version) {
        $package_version = "$($version.Major).$($version.Minor).$($version.Patch)"
        if ($version.BranchName -ne "master") {
            $package_version += "-build" + $build_number.ToString().PadLeft(5, '0')
        }

        $package_version

        gci "$output_directory\*.nuspec" | % {
            exec { 
                & $nuget_path pack $_ -o $output_directory -version $package_version 
            }
        }
    } else {
        Write-Output "Warning: could not get version. No packages will be created."
    }
}

function EnsureDirectory {
    param($directory)

    if(!(test-path $directory)) {
        mkdir $directory
    }
}

function Get-SolutionPackages {
    $repositories = [xml](Get-Content "$src_directory\packages\repositories.config")
    Select-Xml -Xml $repositories -Xpath "/repositories/repository" | % {
        $_.Node.Attributes["path"].Value
    }
}

function Get-Version {
    $tag = & git describe --exact-match HEAD

    return $tag
}

function ILMerge {
    param(
        [string] $target,
        [string[]] $merge,
        [bool] $internalize = $true
    )

    "<configuration>
  <startup>
    <supportedRuntime version=""v2.0.50727""/>
    <supportedRuntime version=""v4.0""/>
  </startup>
</configuration>" | Out-File -FilePath "$ilmerge_path.config"

    if ($internalize -eq $true) {
        $internalize_flag = "-internalize"
    }
    else {
        $internalize_flag = $null
    }

    $primary = "$output_directory\$target.dll"

    $merge = $merge |%  { "$output_directory\$_.dll" }

    $merged_directory = "$output_directory\$target"

    $out = "$merged_directory\$target.dll"

    EnsureDirectory $merged_directory

    Clean-Item $merged_directory
    
    & $ilmerge_path -keyfile:"$src_directory\ravendb\Raven.Database\RavenDB.snk" -lib:$output_directory -targetplatform:v4 -wildcards $internalize_flag -allowDup -parallel -target:library -log -out:$out $primary $merge
}

function RunTest {
    param(
        [string] $test_project
    )

    & $testrunner_path "$output_directory\$test_project.dll" -teamcity
}


function FindTool {
    param(
        [string] $name
    )

    $result = Get-ChildItem "$package_directory\$name" | Select-Object -First 1

    return $result.FullName
}