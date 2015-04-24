properties {
    $solution           = "df-ravendb.sln"
    $target_config      = "Release"

    $base_directory     = Resolve-Path .
    $src_directory      = "$base_directory\src"
    $output_directory   = "$base_directory\build"
    $package_directory  = "$src_directory\ravendb\packages"
    $nuget_directory    = "$src_directory\ravendb\.nuget"

    $sln_path           = "$src_directory\$solution"
    $assemblyInfo_path  = "$src_directory\GlobalAssemblyInfo.cs"
    $nuget_path         = "$nuget_directory\nuget.exe"
    $nugetConfig_path   = "$nuget_directory\nuget.config"
    
    $ilmerge_path       = FindTool("ILRepack.*\tools\ILRepack.exe")

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

task default -depends Package

task Init -depends Clean, VersionAssembly

task Compile -depends CompileClr

task Test -depends Compile, TestClr

task Clean {
    EnsureDirectory $output_directory

    Clean-Item $output_directory -ea SilentlyContinue

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
    return;
    Get-SolutionPackages |% {
        "Restoring " + $_
        &$nuget_path install $_ -o $package_directory -configfile $nugetConfig_path
    }
}

task UnFody {
    Write-Output "
    <Weavers>
  <Costura IncludeDebugSymbols='false'>
    <IncludeAssemblies>
        Lucene.Net
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

task CompileClr -depends RestoreNuget, Init, UnFody {
    exec { msbuild /nologo /verbosity:q $sln_path /p:"Configuration=$target_config;TargetFrameworkVersion=$framework_version;OutDir=$output_directory"  }
}

task TestClr -depends CompileClr {
}

Task ILMerge -depends Compile {
    $merge = @(
        "ICSharpCode.*",
        "Mono.*"
    )

    ILMerge -target "Raven.Abstractions" -merge $merge
    
    Copy-Item "$output_directory\Raven.Abstractions\Raven.Abstractions.*" $output_directory

    $merge = @(
        "Spatial4n.Core.NTS",
        "NetTopologySuite",
        "PowerCollections",
        "GeoAPI"
    )

    ILMerge -target "Raven.Abstractions" -merge $merge -internalize $false
    
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
        "NLog",
        "Owin",
        "Newtonsoft.Json",
        "Voron"
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
    gci $src_directory -Recurse "packages.config" -ea SilentlyContinue | foreach-object { $_.FullName }
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

function FindTool {
    param(
        [string] $name
    )

    $result = Get-ChildItem "$package_directory\$name" | Select-Object -First 1

    return $result.FullName
}