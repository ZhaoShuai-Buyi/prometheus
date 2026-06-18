# Prometheus 2.47.0 Non-pprof 打包与验证说明

本文档对应 `Prometheus 2.47.0` 的安全改造版本，目标是通过源码修改和重新编译，交付一个默认不暴露 `pprof` 接口的 Prometheus 安装包。

默认约定：

- 工作区根目录：`D:\myPro\ai-tools\prometheus-non-pprof`
- Prometheus 源码目录：`D:\myPro\ai-tools\prometheus-non-pprof\prometheus`
- 下文所有命令，默认都在 `prometheus` 目录执行
- Prometheus Web 监听端口默认使用 `9090`

## 1. IoTDB 如何搭配使用修改后的安全版 Prometheus
第一章按下面顺序操作即可，完成后能同时达到这 3 个目标：

- Prometheus 自身 `9090` 开启鉴权
- IoTDB 指标端口 `9091/9092` 开启鉴权
- 使用本项目编译出的 Prometheus 包，`pprof` 默认关闭

### 步骤 1：生成 Prometheus Web 登录密码的 `bcrypt` 密文

在 Linux、WSL 或 Git Bash 且已安装 `htpasswd` 的环境里执行：

```bash
htpasswd -nBC 10 "" | tr -d ':\n'
```

按提示输入两次密码，记下输出结果，下面要填到 `web-config.yml`。

### 步骤 2：准备 Prometheus 的 `web-config.yml`

新建一个 `web-config.yml`，内容如下：

```yaml
basic_auth_users:
  prom_admin: <bcrypt_password_hash>
```

把 `<bcrypt_password_hash>` 替换成上一步生成的密文。  
如果你暂时不用 TLS，就只保留上面这段配置。

### 步骤 3：修改 IoTDB 节点配置并重启所有节点

IoTDB 默认账号密码示例：

- 用户名：`root`
- 密码：`TimechoDB@2021`

对应的 Base64 值：

- `metric_prometheus_reporter_username=cm9vdA==`
- `metric_prometheus_reporter_password=VGltZWNob0RCQDIwMjE=`

把下面配置加到 IoTDB 对应节点配置中：

```properties
cn_metric_reporter_list=PROMETHEUS
cn_metric_prometheus_reporter_port=9091
cn_metric_level=IMPORTANT

dn_metric_reporter_list=PROMETHEUS
dn_metric_prometheus_reporter_port=9092
dn_metric_level=IMPORTANT

metric_prometheus_reporter_username=cm9vdA==
metric_prometheus_reporter_password=VGltZWNob0RCQDIwMjE=
```

修改完成后，重启所有 IoTDB 节点。

### 步骤 4：修改 Prometheus 安装目录下的 `prometheus.yml`

#### 单机或本地验证示例

```yaml
scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "confignode"
    basic_auth:
      username: "root"
      password: "TimechoDB@2021"
    static_configs:
      - targets: ["127.0.0.1:9091"]
    honor_labels: true

  - job_name: "datanode"
    basic_auth:
      username: "root"
      password: "TimechoDB@2021"
    static_configs:
      - targets: ["127.0.0.1:9092"]
    honor_labels: true
```

#### 多节点示例

```yaml
scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "confignode"
    basic_auth:
      username: "root"
      password: "TimechoDB@2021"
    static_configs:
      - targets: ["iotdb-1:9091", "iotdb-2:9091", "iotdb-3:9091"]
    honor_labels: true

  - job_name: "datanode"
    basic_auth:
      username: "root"
      password: "TimechoDB@2021"
    static_configs:
      - targets: ["iotdb-1:9092", "iotdb-2:9092", "iotdb-3:9092"]
    honor_labels: true
```

如果你修改了 IoTDB 的监控账号密码，这里的 `basic_auth` 也要同步修改。

### 步骤 5：检查 Prometheus 配置文件

Windows：

```powershell
.\dist\windows-amd64\promtool.exe check web-config C:\path\to\web-config.yml
.\dist\windows-amd64\promtool.exe check config .\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.yml
```

Linux：

```bash
./dist/linux-amd64/promtool check web-config /path/to/web-config.yml
./dist/linux-amd64/promtool check config ./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus.yml
```

### 步骤 6：启动本项目编译出的 Prometheus

本项目编译出的包已经禁用了 `pprof`，只要使用这里的二进制启动即可。

Windows：

```powershell
New-Item -ItemType Directory -Force .\.tmp\verify\data | Out-Null

.\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.exe `
  --config.file=.\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.yml `
  --web.config.file=C:\path\to\web-config.yml `
  --storage.tsdb.path=.\.tmp\verify\data
```

Linux：

```bash
mkdir -p ./.tmp/verify/data

./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus \
  --config.file=./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus.yml \
  --web.config.file=/path/to/web-config.yml \
  --storage.tsdb.path=./.tmp/verify/data
```

如果你是通过系统服务启动，也要把 `--web.config.file` 加到服务启动命令里。

### 完成后的预期结果

- 访问 `http://127.0.0.1:9090/metrics` 时，需要输入 Prometheus 的账号密码
- 访问 IoTDB 的 `9091` 或 `9092` 指标地址时，需要输入 IoTDB 的账号密码
- Prometheus `targets` 页面可以正常抓到 `confignode` 和 `datanode`
- 访问 `http://127.0.0.1:9090/debug/pprof/goroutine` 时，带正确 Prometheus 账号密码后应返回 `404`

## 2. 验证

### 2.1 验证 `pprof` 已禁用

这一步的关键判断标准不是“能不能打开这个地址”，而是：

- Prometheus 正常服务：`/-/healthy` 返回 `200`
- 指标接口正常：`/metrics` 返回 `200`
- `pprof` 路径已经不存在：`/debug/pprof/goroutine` 返回 `404`
- 浏览器打开 `http://127.0.0.1:9090/debug/pprof/goroutine` 时看到 `404 page not found`，这就是禁用成功

如果你同时给 Prometheus Web 配置了认证，那么未带认证访问时通常会先得到 `401`。这种情况下，必须在“带正确账号密码”的前提下再去访问 `/debug/pprof/goroutine`，预期结果才应该是 `404`。

#### Windows

先启动 Prometheus：

```powershell
New-Item -ItemType Directory -Force .\.tmp\verify\data | Out-Null

.\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.exe `
  --config.file=.\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.yml `
  --storage.tsdb.path=.\.tmp\verify\data
```

另开一个 PowerShell 窗口验证：

```powershell
curl.exe -i http://127.0.0.1:9090/-/healthy
curl.exe -i http://127.0.0.1:9090/metrics
curl.exe -i http://127.0.0.1:9090/debug/pprof/goroutine
curl.exe -i http://127.0.0.1:9090/debug/pprof/cmdline
```

快速只看状态码：

```powershell
curl.exe -s -o NUL -w "%{http_code}" http://127.0.0.1:9090/-/healthy
curl.exe -s -o NUL -w "%{http_code}" http://127.0.0.1:9090/metrics
curl.exe -s -o NUL -w "%{http_code}" http://127.0.0.1:9090/debug/pprof/goroutine
curl.exe -s -o NUL -w "%{http_code}" http://127.0.0.1:9090/debug/pprof/cmdline
```

浏览器验证地址：

- `http://127.0.0.1:9090/-/healthy`
- `http://127.0.0.1:9090/metrics`
- `http://127.0.0.1:9090/debug/pprof/goroutine`
- `http://127.0.0.1:9090/debug/pprof/cmdline`

预期结果：

- `/-/healthy` 为 `200`
- `/metrics` 为 `200`
- `/debug/pprof/goroutine` 为 `404`
- `/debug/pprof/cmdline` 为 `404`

#### Linux

先启动 Prometheus：

```bash
mkdir -p ./.tmp/verify/data

./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus \
  --config.file=./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus.yml \
  --storage.tsdb.path=./.tmp/verify/data
```

另开一个终端验证：

```bash
curl -i http://127.0.0.1:9090/-/healthy
curl -i http://127.0.0.1:9090/metrics
curl -i http://127.0.0.1:9090/debug/pprof/goroutine
curl -i http://127.0.0.1:9090/debug/pprof/cmdline
```

快速只看状态码：

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9090/-/healthy
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9090/metrics
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9090/debug/pprof/goroutine
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9090/debug/pprof/cmdline
```

浏览器验证地址：

- `http://127.0.0.1:9090/-/healthy`
- `http://127.0.0.1:9090/metrics`
- `http://127.0.0.1:9090/debug/pprof/goroutine`
- `http://127.0.0.1:9090/debug/pprof/cmdline`

预期结果：

- `/-/healthy` 为 `200`
- `/metrics` 为 `200`
- `/debug/pprof/goroutine` 为 `404`
- `/debug/pprof/cmdline` 为 `404`

### 2.2 验证 Prometheus 配置的密码是否生效

如果给 Prometheus Web 配置了 `--web.config.file`，建议先做一次静态检查，再做运行时验证。

#### 静态检查

Windows：

```powershell
.\dist\windows-amd64\promtool.exe check web-config C:\path\to\web-config.yml
```

Linux：

```bash
./dist/linux-amd64/promtool check web-config /path/to/web-config.yml
```

#### 运行时验证

启动时增加你的认证配置文件，例如：

Windows：

```powershell
New-Item -ItemType Directory -Force .\.tmp\verify\data | Out-Null

.\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.exe `
  --config.file=.\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.yml `
  --web.config.file=C:\path\to\web-config.yml `
  --storage.tsdb.path=.\.tmp\verify\data
```

Linux：

```bash
mkdir -p ./.tmp/verify/data

./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus \
  --config.file=./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus.yml \
  --web.config.file=/path/to/web-config.yml \
  --storage.tsdb.path=./.tmp/verify/data
```

运行时检查标准：

- 不带认证访问 `/-/healthy`，预期为 `401`
- 带错误密码访问 `/-/healthy`，预期仍为 `401`
- 带正确密码访问 `/-/healthy`，预期为 `200`
- 带正确密码访问 `/debug/pprof/goroutine`，预期为 `404`

Windows：

```powershell
curl.exe -i http://127.0.0.1:9090/-/healthy
curl.exe -i -u <PROM_USERNAME>:wrong-password http://127.0.0.1:9090/-/healthy
curl.exe -i -u <PROM_USERNAME>:<PROM_PASSWORD> http://127.0.0.1:9090/-/healthy
curl.exe -i -u <PROM_USERNAME>:<PROM_PASSWORD> http://127.0.0.1:9090/debug/pprof/goroutine
```

Linux：

```bash
curl -i http://127.0.0.1:9090/-/healthy
curl -i -u <PROM_USERNAME>:wrong-password http://127.0.0.1:9090/-/healthy
curl -i -u <PROM_USERNAME>:<PROM_PASSWORD> http://127.0.0.1:9090/-/healthy
curl -i -u <PROM_USERNAME>:<PROM_PASSWORD> http://127.0.0.1:9090/debug/pprof/goroutine
```

浏览器验证时，先访问：

- `http://127.0.0.1:9090/`

如果浏览器弹出认证框，输入正确账号密码后：

- 页面应能正常打开
- 再访问 `http://127.0.0.1:9090/debug/pprof/goroutine`，应显示 `404 page not found`

### 2.3 验证 IoTDB 配置的密码是否生效

这一部分依赖你们实际的 IoTDB 暴露方式。下面给出通用验证思路，使用时请把地址、端口、路径、用户名和密码替换成你们自己的真实值。

如果 Prometheus 是抓取 IoTDB 暴露的指标接口：

- 用错误密码直接访问 IoTDB 指标接口，预期返回 `401` 或 `403`
- 用正确密码访问同一个接口，预期返回 `200`
- Prometheus 启动后访问 `http://127.0.0.1:9090/targets`，对应目标应为 `UP`

Windows：

```powershell
curl.exe -i -u <IOTDB_USERNAME>:wrong-password http://<IOTDB_HOST>:<IOTDB_PORT>/<METRICS_PATH>
curl.exe -i -u <IOTDB_USERNAME>:<IOTDB_PASSWORD> http://<IOTDB_HOST>:<IOTDB_PORT>/<METRICS_PATH>
```

Linux：

```bash
curl -i -u <IOTDB_USERNAME>:wrong-password http://<IOTDB_HOST>:<IOTDB_PORT>/<METRICS_PATH>
curl -i -u <IOTDB_USERNAME>:<IOTDB_PASSWORD> http://<IOTDB_HOST>:<IOTDB_PORT>/<METRICS_PATH>
```

如果 Prometheus 与 IoTDB 之间不是普通抓取，而是 `remote_write`、`remote_read` 或者你们自己的适配层：

- 先用错误密码启动，预期相关日志里会出现 `401`、`403` 或鉴权失败信息
- 再改回正确密码启动，预期鉴权失败日志消失，链路恢复正常
- 如果适配层本身也提供 HTTP 接口，优先对那个真实被 Prometheus 使用的地址做上面的“错误密码 / 正确密码”直连验证

## 3. 安装包位置

为了尽量贴近官方 release，建议最终压缩包采用以下命名：

- Windows amd64：`prometheus-2.47.0-non-pprof-windows-amd64.zip`
- Linux amd64：`prometheus-2.47.0-non-pprof-linux-amd64.tar.gz`
- Linux arm64：`prometheus-2.47.0-non-pprof-linux-arm64.tar.gz`
- Linux armv7：`prometheus-2.47.0-non-pprof-linux-armv7.tar.gz`

构建完成后，压缩包默认放在 `dist` 目录，未压缩的安装目录默认放在 `package` 目录。

Windows：

- 安装目录：`D:\myPro\ai-tools\prometheus-non-pprof\prometheus\package\prometheus-2.47.0-non-pprof-windows-amd64`
- 压缩包：`D:\myPro\ai-tools\prometheus-non-pprof\prometheus\dist\prometheus-2.47.0-non-pprof-windows-amd64.zip`

Linux：

- amd64 安装目录：`./package/prometheus-2.47.0-non-pprof-linux-amd64`
- amd64 压缩包：`./dist/prometheus-2.47.0-non-pprof-linux-amd64.tar.gz`
- arm64 安装目录：`./package/prometheus-2.47.0-non-pprof-linux-arm64`
- arm64 压缩包：`./dist/prometheus-2.47.0-non-pprof-linux-arm64.tar.gz`
- armv7 安装目录：`./package/prometheus-2.47.0-non-pprof-linux-armv7`
- armv7 压缩包：`./dist/prometheus-2.47.0-non-pprof-linux-armv7.tar.gz`

如果 `dist` 或 `package` 下还有带 `-non-pprof.1-` 的旧产物，那是之前生成的旧命名包，重新按本文打包后会得到新的命名。

## 4. 各种操作系统的打包方式

### 4.1 目标包结构

为了尽量靠近官方 release，建议每个安装目录至少包含这些内容：

```text
prometheus-2.47.0-non-pprof-<os>-<arch>/
  prometheus[.exe]
  promtool[.exe]
  prometheus.yml
  consoles/
  console_libraries/
  LICENSE
  NOTICE
  npm_licenses.tar.bz2
```

说明：

- `promtool` 建议一并打包，方便做配置检查和后续运维排障
- `consoles` 和 `console_libraries` 建议保留，避免与官方 release 差异过大
- `npm_licenses.tar.bz2` 主要用于前端依赖许可证归档，不影响运行，但为了接近官方 release，建议一并带上
- 不建议把 `data` 目录预先打进安装包，官方 release 也不依赖它；启动时由 Prometheus 自动创建即可

### 4.2 前置条件

Windows 和 Linux 都需要：

- `git`
- `go`
- `node`
- `npm`

建议版本：

- Go `1.21+`
- Node.js `18+`
- npm `9+`

前端资源和 `npm_licenses.tar.bz2` 在同一份源码目录里通常只需要准备一次。后续如果只是切换 `GOARCH` 再打 `linux-arm64` 或 `linux-armv7`，可以直接复用已经生成好的前端资源。

### 4.3 Windows amd64 打包

#### 4.3.1 准备本地缓存目录和环境变量

```powershell
New-Item -ItemType Directory -Force .\.cache\go-build, .\.cache\go-mod, .\.cache\go-telemetry, .\.cache\npm, .\.tmp, .\.appdata\roaming, .\.appdata\local, .\dist, .\package | Out-Null

$env:GOCACHE = (Resolve-Path .\.cache\go-build).Path
$env:GOMODCACHE = (Resolve-Path .\.cache\go-mod).Path
$env:GOTELEMETRY = "off"
$env:GOTELEMETRYDIR = (Resolve-Path .\.cache\go-telemetry).Path
$env:TMP = (Resolve-Path .\.tmp).Path
$env:TEMP = (Resolve-Path .\.tmp).Path
$env:APPDATA = (Resolve-Path .\.appdata\roaming).Path
$env:LOCALAPPDATA = (Resolve-Path .\.appdata\local).Path
$env:npm_config_cache = (Resolve-Path .\.cache\npm).Path
$env:GOPROXY = "https://proxy.golang.org,direct"
$env:CGO_ENABLED = "0"
```

#### 4.3.2 安装前端依赖

```powershell
Push-Location .\web\ui
npm.cmd ci
Pop-Location
```

#### 4.3.3 构建 `lezer-promql`

```powershell
Push-Location .\web\ui\module\lezer-promql

npx.cmd lezer-generator src/promql.grammar -o src/parser
[System.IO.File]::AppendAllText((Resolve-Path .\src\parser.js).Path, [Environment]::NewLine + [System.IO.File]::ReadAllText((Resolve-Path .\src\parser.terms.js).Path))

$parserTerms = [System.IO.File]::ReadAllText((Resolve-Path .\src\parser.terms.js).Path)
$parserTypes = [System.Text.RegularExpressions.Regex]::Replace($parserTerms, " = [0-9]+", ": number")
$typeFile = @(
  "// Copyright 2021 The Prometheus Authors"
  "//"
  "// Licensed under the Apache License, Version 2.0 (the ""License"");"
  "// you may not use this file except in compliance with the License."
  "// You may obtain a copy of the License at"
  "//"
  "//    http://www.apache.org/licenses/LICENSE-2.0"
  "//"
  "// Unless required by applicable law or agreed to in writing, software"
  "// distributed under the License is distributed on an ""AS IS"" BASIS,"
  "// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied."
  "// See the License for the specific language governing permissions and"
  "// limitations under the License."
  ""
  "// This file was generated by lezer-promql. You probably should not edit it."
  "import { LRParser } from '@lezer/lr'"
  ""
  "export const parser: LRParser"
  $parserTypes.TrimEnd()
  ""
) -join [Environment]::NewLine

New-Item -ItemType Directory -Force .\dist | Out-Null
[System.IO.File]::WriteAllText((Resolve-Path .\dist).Path + "\index.d.ts", $typeFile)
npx.cmd rollup -c

Copy-Item .\src\tokens.js .\dist\tokens.js -Force
Copy-Item .\src\highlight.js .\dist\highlight.js -Force
Copy-Item .\src\parser.terms.js .\dist\parser.terms.js -Force

Pop-Location
```

#### 4.3.4 构建 `codemirror-promql`

```powershell
Push-Location .\web\ui\module\codemirror-promql
npx.cmd tsc --module esnext --target es2018 --outDir dist/esm
npx.cmd tsc --module commonjs --target es5 --outDir dist/cjs --downlevelIteration
Pop-Location
```

#### 4.3.5 构建 React 静态资源

```powershell
Push-Location .\web\ui
$env:GENERATE_SOURCEMAP = "false"
$env:DISABLE_ESLINT_PLUGIN = "true"
npm.cmd run build -w @prometheus-io/app

if (Test-Path .\static\react) {
  Remove-Item -LiteralPath .\static\react -Recurse -Force
}

Move-Item -LiteralPath .\react-app\build -Destination .\static\react
Pop-Location
```

#### 4.3.6 生成 `web/ui/embed.go`

```powershell
Push-Location .\web\ui

$tmpl = Get-Content .\embed.go.tmpl -Raw
[System.IO.File]::WriteAllText((Resolve-Path .).Path + "\embed.go", $tmpl.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine)

Get-ChildItem .\static -Recurse -File -Filter *.gz | Remove-Item -Force

foreach ($file in Get-ChildItem .\static -Recurse -File | Sort-Object FullName) {
  $gzipPath = $file.FullName + ".gz"
  $srcBytes = [System.IO.File]::ReadAllBytes($file.FullName)
  $fs = [System.IO.File]::Create($gzipPath)
  try {
    $gz = New-Object System.IO.Compression.GzipStream($fs, [System.IO.Compression.CompressionLevel]::Optimal)
    try {
      $gz.Write($srcBytes, 0, $srcBytes.Length)
    } finally {
      $gz.Dispose()
    }
  } finally {
    $fs.Dispose()
  }

  $relative = $gzipPath.Substring((Resolve-Path .).Path.Length + 1).Replace('\', '/')
  Add-Content .\embed.go "//go:embed $relative"
}

Add-Content .\embed.go "var EmbedFS embed.FS"
Pop-Location
```

#### 4.3.7 生成 `npm_licenses.tar.bz2`

```powershell
Remove-Item .\npm_licenses.tar.bz2 -Force -ErrorAction SilentlyContinue

Get-ChildItem .\web\ui\node_modules -Recurse -File | Where-Object {
  $_.Name -like "license*"
} | ForEach-Object {
  $_.FullName.Substring((Resolve-Path .).Path.Length + 1).Replace('\', '/')
} | Set-Content .\.tmp\npm-license-files.txt -Encoding ascii

tar.exe -cjf .\npm_licenses.tar.bz2 -T .\.tmp\npm-license-files.txt
```

如果这一步因为本机 `tar.exe` 能力差异失败，可以临时跳过，不影响运行；但如果你的目标是尽量贴近官方 release，建议把它补上。

#### 4.3.8 构建 Windows 二进制

```powershell
$Version = "2.47.0-non-pprof"
$Revision = (git rev-parse HEAD).Trim()
$Branch = (git rev-parse --abbrev-ref HEAD).Trim()
$BuildDate = Get-Date -Format "yyyyMMdd-HH:mm:ss"
$BuildUser = "$env:USERNAME@$env:COMPUTERNAME"

$LDFLAGS = @(
  "-X github.com/prometheus/common/version.Version=$Version"
  "-X github.com/prometheus/common/version.Revision=$Revision"
  "-X github.com/prometheus/common/version.Branch=$Branch"
  "-X github.com/prometheus/common/version.BuildUser=$BuildUser"
  "-X github.com/prometheus/common/version.BuildDate=$BuildDate"
) -join " "

$env:GOOS = "windows"
$env:GOARCH = "amd64"

New-Item -ItemType Directory -Force .\dist\windows-amd64 | Out-Null

go build -trimpath -tags "builtinassets,stringlabels" -ldflags $LDFLAGS -o .\dist\windows-amd64\prometheus.exe .\cmd\prometheus
go build -trimpath -tags "builtinassets,stringlabels" -ldflags $LDFLAGS -o .\dist\windows-amd64\promtool.exe .\cmd\promtool
```

#### 4.3.9 组装并压缩 Windows 安装包

```powershell
$PkgName = "prometheus-2.47.0-non-pprof-windows-amd64"
$PkgDir = ".\package\$PkgName"

if (Test-Path $PkgDir) {
  Remove-Item -LiteralPath $PkgDir -Recurse -Force
}

New-Item -ItemType Directory -Force $PkgDir | Out-Null

Copy-Item .\dist\windows-amd64\prometheus.exe $PkgDir -Force
Copy-Item .\dist\windows-amd64\promtool.exe $PkgDir -Force
Copy-Item .\consoles $PkgDir -Recurse -Force
Copy-Item .\console_libraries $PkgDir -Recurse -Force
Copy-Item .\documentation\examples\prometheus.yml (Join-Path $PkgDir "prometheus.yml") -Force
Copy-Item .\LICENSE $PkgDir -Force
Copy-Item .\NOTICE $PkgDir -Force

if (Test-Path .\npm_licenses.tar.bz2) {
  Copy-Item .\npm_licenses.tar.bz2 $PkgDir -Force
}

Remove-Item ".\dist\$PkgName.zip" -Force -ErrorAction SilentlyContinue
Compress-Archive -Path $PkgDir -DestinationPath ".\dist\$PkgName.zip"
```

#### 4.3.10 可选检查

```powershell
.\dist\windows-amd64\prometheus.exe --version
.\dist\windows-amd64\promtool.exe --version
.\dist\windows-amd64\promtool.exe check config .\package\prometheus-2.47.0-non-pprof-windows-amd64\prometheus.yml
```

### 4.4 Linux amd64 打包

#### 4.4.1 准备本地缓存目录和环境变量

```bash
mkdir -p .cache/go-build .cache/go-mod .cache/go-telemetry .cache/npm .tmp dist package

export GOCACHE="$PWD/.cache/go-build"
export GOMODCACHE="$PWD/.cache/go-mod"
export GOTELEMETRY=off
export GOTELEMETRYDIR="$PWD/.cache/go-telemetry"
export TMPDIR="$PWD/.tmp"
export npm_config_cache="$PWD/.cache/npm"
export GOPROXY="https://proxy.golang.org,direct"
export CGO_ENABLED=0
```

#### 4.4.2 安装前端依赖并构建前端资源

```bash
cd web/ui
npm ci
npm run build:module
DISABLE_ESLINT_PLUGIN=true GENERATE_SOURCEMAP=false npm run build -w @prometheus-io/app
rm -rf static/react
mv react-app/build static/react
cd ../..
```

#### 4.4.3 生成 `web/ui/embed.go`

```bash
cd web/ui
cp embed.go.tmpl embed.go
GZIP_OPTS="-fk"
gzip -k -h >/dev/null 2>&1 || GZIP_OPTS="-f"
find static -type f -name '*.gz' -delete
find static -type f -exec gzip $GZIP_OPTS '{}' \; -print0 | xargs -0 -I % echo "//go:embed %.gz" >> embed.go
echo "var EmbedFS embed.FS" >> embed.go
cd ../..
```

#### 4.4.4 生成 `npm_licenses.tar.bz2`

```bash
rm -f npm_licenses.tar.bz2
find web/ui/node_modules -type f -iname 'license*' | tar -cjf npm_licenses.tar.bz2 -T -
```

#### 4.4.5 构建 Linux amd64 二进制

```bash
VERSION="2.47.0-non-pprof"
REVISION="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILD_DATE="$(date +%Y%m%d-%H:%M:%S)"
BUILD_USER="$(whoami)@$(hostname)"

LDFLAGS="-X github.com/prometheus/common/version.Version=${VERSION} \
-X github.com/prometheus/common/version.Revision=${REVISION} \
-X github.com/prometheus/common/version.Branch=${BRANCH} \
-X github.com/prometheus/common/version.BuildUser=${BUILD_USER} \
-X github.com/prometheus/common/version.BuildDate=${BUILD_DATE}"

mkdir -p ./dist/linux-amd64

GOOS=linux GOARCH=amd64 go build -trimpath -tags "netgo,builtinassets,stringlabels" -ldflags "$LDFLAGS" -o ./dist/linux-amd64/prometheus ./cmd/prometheus
GOOS=linux GOARCH=amd64 go build -trimpath -tags "netgo,builtinassets,stringlabels" -ldflags "$LDFLAGS" -o ./dist/linux-amd64/promtool ./cmd/promtool
```

#### 4.4.6 组装并压缩 Linux amd64 安装包

```bash
PKG_NAME="prometheus-2.47.0-non-pprof-linux-amd64"
PKG_DIR="./package/${PKG_NAME}"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

cp ./dist/linux-amd64/prometheus "$PKG_DIR/"
cp ./dist/linux-amd64/promtool "$PKG_DIR/"
cp -r ./consoles "$PKG_DIR/"
cp -r ./console_libraries "$PKG_DIR/"
cp ./documentation/examples/prometheus.yml "$PKG_DIR/prometheus.yml"
cp ./LICENSE ./NOTICE "$PKG_DIR/"

if [ -f ./npm_licenses.tar.bz2 ]; then
  cp ./npm_licenses.tar.bz2 "$PKG_DIR/"
fi

rm -f "./dist/${PKG_NAME}.tar.gz"
tar -C ./package -czf "./dist/${PKG_NAME}.tar.gz" "${PKG_NAME}"
```

#### 4.4.7 可选检查

```bash
./dist/linux-amd64/prometheus --version
./dist/linux-amd64/promtool --version
./dist/linux-amd64/promtool check config ./package/prometheus-2.47.0-non-pprof-linux-amd64/prometheus.yml
```

### 4.5 Linux arm64 打包

如果这份源码目录已经完成过 Linux 前端资源准备，可以直接复用 `web/ui/static/react`、`web/ui/embed.go` 和 `npm_licenses.tar.bz2`，只重新编译 arm64 二进制并重新组包。

```bash
export GOCACHE="$PWD/.cache/go-build"
export GOMODCACHE="$PWD/.cache/go-mod"
export GOTELEMETRY=off
export GOTELEMETRYDIR="$PWD/.cache/go-telemetry"
export TMPDIR="$PWD/.tmp"
export GOPROXY="https://proxy.golang.org,direct"
export CGO_ENABLED=0

VERSION="2.47.0-non-pprof"
REVISION="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILD_DATE="$(date +%Y%m%d-%H:%M:%S)"
BUILD_USER="$(whoami)@$(hostname)"

LDFLAGS="-X github.com/prometheus/common/version.Version=${VERSION} \
-X github.com/prometheus/common/version.Revision=${REVISION} \
-X github.com/prometheus/common/version.Branch=${BRANCH} \
-X github.com/prometheus/common/version.BuildUser=${BUILD_USER} \
-X github.com/prometheus/common/version.BuildDate=${BUILD_DATE}"

mkdir -p ./dist/linux-arm64

GOOS=linux GOARCH=arm64 go build -trimpath -tags "netgo,builtinassets,stringlabels" -ldflags "$LDFLAGS" -o ./dist/linux-arm64/prometheus ./cmd/prometheus
GOOS=linux GOARCH=arm64 go build -trimpath -tags "netgo,builtinassets,stringlabels" -ldflags "$LDFLAGS" -o ./dist/linux-arm64/promtool ./cmd/promtool

PKG_NAME="prometheus-2.47.0-non-pprof-linux-arm64"
PKG_DIR="./package/${PKG_NAME}"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

cp ./dist/linux-arm64/prometheus "$PKG_DIR/"
cp ./dist/linux-arm64/promtool "$PKG_DIR/"
cp -r ./consoles "$PKG_DIR/"
cp -r ./console_libraries "$PKG_DIR/"
cp ./documentation/examples/prometheus.yml "$PKG_DIR/prometheus.yml"
cp ./LICENSE ./NOTICE "$PKG_DIR/"

if [ -f ./npm_licenses.tar.bz2 ]; then
  cp ./npm_licenses.tar.bz2 "$PKG_DIR/"
fi

rm -f "./dist/${PKG_NAME}.tar.gz"
tar -C ./package -czf "./dist/${PKG_NAME}.tar.gz" "${PKG_NAME}"
```

### 4.6 Linux armv7 打包

同样复用已经生成好的前端资源，只重新编译 armv7 二进制并重新组包。

```bash
export GOCACHE="$PWD/.cache/go-build"
export GOMODCACHE="$PWD/.cache/go-mod"
export GOTELEMETRY=off
export GOTELEMETRYDIR="$PWD/.cache/go-telemetry"
export TMPDIR="$PWD/.tmp"
export GOPROXY="https://proxy.golang.org,direct"
export CGO_ENABLED=0

VERSION="2.47.0-non-pprof"
REVISION="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILD_DATE="$(date +%Y%m%d-%H:%M:%S)"
BUILD_USER="$(whoami)@$(hostname)"

LDFLAGS="-X github.com/prometheus/common/version.Version=${VERSION} \
-X github.com/prometheus/common/version.Revision=${REVISION} \
-X github.com/prometheus/common/version.Branch=${BRANCH} \
-X github.com/prometheus/common/version.BuildUser=${BUILD_USER} \
-X github.com/prometheus/common/version.BuildDate=${BUILD_DATE}"

mkdir -p ./dist/linux-armv7

GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -tags "netgo,builtinassets,stringlabels" -ldflags "$LDFLAGS" -o ./dist/linux-armv7/prometheus ./cmd/prometheus
GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -tags "netgo,builtinassets,stringlabels" -ldflags "$LDFLAGS" -o ./dist/linux-armv7/promtool ./cmd/promtool

PKG_NAME="prometheus-2.47.0-non-pprof-linux-armv7"
PKG_DIR="./package/${PKG_NAME}"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

cp ./dist/linux-armv7/prometheus "$PKG_DIR/"
cp ./dist/linux-armv7/promtool "$PKG_DIR/"
cp -r ./consoles "$PKG_DIR/"
cp -r ./console_libraries "$PKG_DIR/"
cp ./documentation/examples/prometheus.yml "$PKG_DIR/prometheus.yml"
cp ./LICENSE ./NOTICE "$PKG_DIR/"

if [ -f ./npm_licenses.tar.bz2 ]; then
  cp ./npm_licenses.tar.bz2 "$PKG_DIR/"
fi

rm -f "./dist/${PKG_NAME}.tar.gz"
tar -C ./package -czf "./dist/${PKG_NAME}.tar.gz" "${PKG_NAME}"
```
