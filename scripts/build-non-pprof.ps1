[CmdletBinding()]
param(
    [string[]]$Targets = @("windows/amd64", "linux/amd64"),
    [string]$OutputRoot = "dist",
    [string]$Version,
    [string]$Revision,
    [string]$Branch
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

try {
    foreach ($dir in @(".cache/go-build", ".cache/go-mod", ".cache/go-telemetry", ".tmp", ".appdata/roaming", ".appdata/local", $OutputRoot)) {
        New-Item -ItemType Directory -Force $dir | Out-Null
    }

    if (-not (Test-Path "web/ui/embed.go") -or -not (Test-Path "web/ui/static/react")) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "prepare-ui-assets.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "UI asset preparation failed"
        }
    }

    $env:GOCACHE = (Resolve-Path ".cache/go-build").Path
    $env:GOMODCACHE = (Resolve-Path ".cache/go-mod").Path
    $env:GOTELEMETRY = "off"
    $env:GOTELEMETRYDIR = (Resolve-Path ".cache/go-telemetry").Path
    $env:TMP = (Resolve-Path ".tmp").Path
    $env:TEMP = (Resolve-Path ".tmp").Path
    $env:APPDATA = (Resolve-Path ".appdata/roaming").Path
    $env:LOCALAPPDATA = (Resolve-Path ".appdata/local").Path
    $env:GOPROXY = "https://proxy.golang.org,direct"
    $env:CGO_ENABLED = "0"

    if (-not $Version) {
        $baseVersion = (Get-Content VERSION -TotalCount 1).Trim()
        if ($baseVersion -like "*-non-pprof") {
            $Version = $baseVersion
        } else {
            $Version = "$baseVersion-non-pprof"
        }
    }
    if (-not $Revision) {
        $Revision = (& git -c "safe.directory=$repoRoot" rev-parse HEAD).Trim()
    }
    if (-not $Branch) {
        $Branch = (& git -c "safe.directory=$repoRoot" rev-parse --abbrev-ref HEAD).Trim()
    }

    $buildDate = Get-Date -Format "yyyyMMdd-HH:mm:ss"
    $buildUser = "$env:USERNAME@$env:COMPUTERNAME"
    $ldflags = @(
        "-X github.com/prometheus/common/version.Version=$Version"
        "-X github.com/prometheus/common/version.Revision=$Revision"
        "-X github.com/prometheus/common/version.Branch=$Branch"
        "-X github.com/prometheus/common/version.BuildUser=$buildUser"
        "-X github.com/prometheus/common/version.BuildDate=$buildDate"
    ) -join " "

    foreach ($target in $Targets) {
        $parts = $target.Split("/")
        if ($parts.Length -lt 2 -or $parts.Length -gt 3) {
            throw "Unsupported target format: $target"
        }

        $goos = $parts[0]
        $goarch = $parts[1]
        $variant = if ($parts.Length -eq 3) { $parts[2] } else { "" }
        $tags = if ($goos -eq "windows") {
            "builtinassets,stringlabels"
        } else {
            "netgo,builtinassets,stringlabels"
        }

        $env:GOOS = $goos
        $env:GOARCH = $goarch
        if ($goarch -eq "arm") {
            $env:GOARM = if ($variant) { $variant } else { "7" }
        } else {
            Remove-Item Env:GOARM -ErrorAction SilentlyContinue
        }

        $targetDirName = if ($goarch -eq "arm") {
            "$goos-$goarch" + "v" + $env:GOARM
        } elseif ($variant) {
            "$goos-$goarch-$variant"
        } else {
            "$goos-$goarch"
        }

        $outDir = Join-Path $OutputRoot $targetDirName
        New-Item -ItemType Directory -Force $outDir | Out-Null

        $binaryName = if ($goos -eq "windows") { "prometheus.exe" } else { "prometheus" }
        $outPath = Join-Path $outDir $binaryName

        Write-Host "Building $target -> $outPath"
        & go build -trimpath -tags $tags -ldflags $ldflags -o $outPath ./cmd/prometheus
        if ($LASTEXITCODE -ne 0) {
            throw "go build failed for $target"
        }
    }
}
finally {
    Pop-Location
}
