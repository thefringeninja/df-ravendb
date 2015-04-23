properties {
    $solution           = "df-ravendb.sln"
    $target_config      = "Release"

    $base_directory     = Resolve-Path .
    $src_directory      = "$base_directory\src"
    $output_directory   = "$base_directory\build"
    $merged_directory   = "$output_directory\merged"
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
    exec { msbuild /nologo /verbosity:q $sln_path /p:"Configuration=$target_config;TargetFrameworkVersion=$framework_version"  }
}

task TestClr -depends CompileClr {
}

Task ILMerge -depends Compile {
    EnsureDirectory $merged_directory

    $merge = @(
    )

    ILMerge -target "RavenDB.Abstractions" -folder $output_directory -merge $merge

    $merge = @(
    )

    ILMerge -target "RavenDB.Client.Lightweight" -folder $output_directory -merge $merge

    $merge = @(
    )

    ILMerge -target "RavenDB.Database" -folder $output_directory -merge $merge
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
        [string] $folder,
        [string[]] $merge
    )

    "<configuration>
  <startup>
    <supportedRuntime version=""v2.0.50727""/>
    <supportedRuntime version=""v4.0""/>
  </startup>
</configuration>" | Out-File -FilePath "$ilmerge_path.config"

    $primary = "$folder\$target.dll"

    $merge = $merge |%  { "$folder\$_.dll" }

    $out = "$merged_directory\$target.dll"
    
    & $ilmerge_path /targetplatform:v4 /wildcards /internalize /allowDup /target:library /log /out:$out $primary $merge
}

function FindTool {
    param(
        [string] $name
    )

    $result = Get-ChildItem "$package_directory\$name" | Select-Object -First 1

    return $result.FullName
}