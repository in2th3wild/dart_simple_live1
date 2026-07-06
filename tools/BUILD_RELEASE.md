# Build Release 流程说明

本说明记录 `dart_simple_live` 本地 release 构建的标准流程，配套脚本为 `tools/build-release.ps1`。所有命令和文件读写都按 UTF-8 执行。

## 环境要求

- Flutter：`C:\softwares\flutter\bin\flutter.bat`
- NuGet：`C:\softwares\nuget\nuget.exe`
- Android SDK：`C:\softwares\Android_Sdk`
- GitHub CLI：`C:\softwares\GitHubCli\gh.exe`
- 代理兜底：`127.0.0.1:51888`

`C:\softwares\flutter\bin` 和 `C:\softwares\nuget` 需要在用户 PATH 中。若刚更新 PATH，建议重新打开终端后再构建。

## 常用命令

```powershell
# 主 App Windows
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -Target Windows

# TV-Windows
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -Target TVWindows

# 主 App 本地全量
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -Target AllLocal
```

## Windows 构建流程

1. 执行 `flutter pub get`。
2. 检查并补齐 `media_kit_libs_windows_video` 的两个 Windows 原生依赖：
   - `mpv-dev-x86_64-20230924-git-652a1dd.7z`
   - `ANGLE.7z`
3. 对依赖包做 MD5 校验：
   - `mpv`：`a832ef24b3a6ff97cd2560b5b9d04cd8`
   - `ANGLE`：`e866f13e8d552348058afaafe869b1ed`
4. 执行 `flutter build windows --release`。
5. 从 `build\windows\x64\runner\Release` 或 `build\windows\x64\install` staging。
6. 如果 staging 中缺 `dart_quickjs.dll`，从 `.dart_tool\hooks_runner\shared\dart_quickjs\**\dart_quickjs.dll` 取最新副本补入。
7. 生成 zip，并校验关键文件。

## 必须校验的 Windows 文件

主 App Windows 包必须包含：

- `simple_live_app.exe`
- `flutter_windows.dll`
- `dart_quickjs.dll`
- `data\flutter_assets\AssetManifest.bin`
- `data\flutter_assets\NativeAssetsManifest.json`

TV-Windows 包必须包含：

- `simple_live_tv_app.exe`
- `flutter_windows.dll`
- `libmpv-2.dll`
- `dart_quickjs.dll`
- `data\app.so`
- `data\flutter_assets\AssetManifest.bin`
- `data\flutter_assets\NativeAssetsManifest.json`

## 常见问题

### NUGET-NOTFOUND

现象：`flutter_inappwebview_windows` 构建阶段报 `NUGET-NOTFOUND`。

处理：

1. 确认 `C:\softwares\nuget\nuget.exe` 存在。
2. 确认 `C:\softwares\nuget` 已在用户 PATH 中。
3. 删除对应项目下：
   - `build\windows\x64\CMakeCache.txt`
   - `build\windows\x64\CMakeFiles`
4. 重新执行 `flutter build windows --release` 或 release 脚本。

### mpv / ANGLE 依赖包校验失败

现象：CMake 报 `Integrity check failed`，或本地 `.7z` 为 0 字节。

处理：

1. 删除坏包。
2. 通过 `curl.exe --proxy socks5h://127.0.0.1:51888 -L` 重新下载。
3. 校验 MD5。
4. 重新构建。

`tools/build-release.ps1` 已内置这一步；如果仍失败，优先检查代理端口是否可用。

### dart_quickjs.dll 缺失

现象：运行时报 `JS_NewRuntime` 或 DLL load failure。

处理：

1. 检查最终 zip，而不是只检查 build 目录。
2. 确认 `dart_quickjs.dll` 在 zip 根目录。
3. 如缺失，从 `.dart_tool\hooks_runner\shared\dart_quickjs\**\dart_quickjs.dll` 复制最新副本。

### Windows 构建长时间无输出

现象：`flutter build windows --release` 输出停在 `Building Windows application...`，几分钟内没有新日志。

处理：

1. 不要只凭终端无输出判断卡死。Windows Release 编译可能在 C++ 阶段长时间静默。
2. 用进程确认是否还在编译，重点看 `flutter.bat`、`dart.exe`、`cmake.exe`、`cl.exe`、`link.exe` 是否仍在运行。
3. 如果能看到 `cmake.exe` / `cl.exe` 仍在当前项目的 `build\windows\x64` 下工作，继续等待。
4. 只有进程消失、日志报错，或同一个编译进程长时间无 CPU/IO 活动时，才按失败处理。

示例检查命令：

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.CommandLine -like '*dart_simple_live*' -or
    $_.CommandLine -like '*flutter*build windows*' -or
    $_.CommandLine -like '*cmake*' -or
    $_.CommandLine -like '*cl.exe*' -or
    $_.CommandLine -like '*link.exe*'
  } |
  Select-Object ProcessId,Name,CommandLine |
  Format-List
```

### 产物时间戳与 zip 路径误判

现象：构建过程中 release 目录仍显示旧 zip，或手工校验 zip 时关键文件显示 `MISSING`。

处理：

1. 构建脚本结束前，release 目录里的 zip 可能仍是旧包；必须等脚本打印 `Build summary` 后再认定最终产物。
2. 构建结束后核对 `LastWriteTime`，如果 zip 时间早于本次源码修改时间，视为旧包，必须重新构建。
3. 本项目 Windows zip 当前是把文件直接放在 zip 根目录，不一定包含 `SimpleLive-Windows-v<版本号>/` 顶层目录；手工校验时不要强行加目录前缀。
4. 校验关键文件时优先按文件名搜索，确认 `simple_live_app.exe`、`flutter_windows.dll`、`dart_quickjs.dll`、`data\flutter_assets\AssetManifest.bin`、`data\flutter_assets\NativeAssetsManifest.json` 都存在。

示例 zip 校验命令：

```powershell
$zip = 'C:\softwares\dart_simple_live\release\v1.12.7\SimpleLive-Windows-v1.12.7.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
  foreach ($name in @(
    'simple_live_app.exe',
    'flutter_windows.dll',
    'dart_quickjs.dll',
    'AssetManifest.bin',
    'NativeAssetsManifest.json'
  )) {
    $archive.Entries |
      Where-Object { $_.FullName -like "*$name" } |
      Select-Object FullName,Length
  }
}
finally {
  $archive.Dispose()
}
```

## 发布目录

- 主 App：`C:\softwares\dart_simple_live\release\v<版本号>`
- TV：`C:\softwares\dart_simple_live\release\tv_v<版本号>`

完成构建后，必须记录并核对：

- 文件 `LastWriteTime`
- 文件大小
- SHA256
- `RELEASE_NOTES.md` UTF-8 回读无乱码

## 全平台 release 补充流程（2026-07-02）

- 正式目录结构：主 App 的 Windows / Android / Linux / macOS / iOS 放入 `release\v1.12.6`；TV / TV-Windows 放入 `release\tv_v1.7.7`，不要把最终产物留在临时 combined staging 目录。
- Linux 本地构建优先使用 WSL Flutter：`/root/tools/flutter_3.38.10/bin/flutter`。如 `mimalloc-2.1.2.tar.gz` 校验失败，删除 0 字节坏包后走 `127.0.0.1:51888` 代理补包，并校验 MD5 `5179c8f5cf1237d2300e2d8559a7bc55`。
- 如果 `flutter_distributor` 在 `/mnt/c` 打 deb 遇到 777 权限或 bundle 路径问题，可使用 Flutter 先生成 `build/linux/x64/release/bundle`，再手工打 zip/deb；deb 的 `DEBIAN` 目录权限必须在 0755 到 0775 之间。
- macOS/iOS 走 GitHub Actions：推送包含 release 修复的临时分支，然后触发 `publish_app_release_macos_manual.yml` 与 `publish_app_release_ios_manual.yml`，参数 `upload_release=false`，下载 artifact 后复制到主 App release 根目录。
- 最终校验必须列出 `LastWriteTime`、`Length`、`SHA256`；Windows zip 要包含 exe、`dart_quickjs.dll`、`NativeAssetsManifest.json`；Android APK 要包含对应 ABI 的 `libdart_quickjs.so`；TV-Windows 同样要包含 exe、`dart_quickjs.dll`、`NativeAssetsManifest.json`。
### 手工替换 Windows release 目录

现象：不走 `tools/build-release.ps1`，而是手工把 `build\windows\x64\runner\Release` 覆盖到 `release\v<version>\SimpleLive-Windows-v<version>`。

处理：

1. 必须先执行 `flutter build windows --release`，不要用旧 debug 目录覆盖正式 release。
2. 删除旧目标目录后，复制 Release 目录的所有子项；PowerShell 中不要用 `Copy-Item -LiteralPath (Join-Path $src '*')`，因为 `-LiteralPath` 不展开通配符。
3. 推荐复制命令：

```powershell
Get-ChildItem -LiteralPath $src -Force |
  Copy-Item -Destination $dst -Recurse -Force
```

4. 如果 Release 根目录缺 `dart_quickjs.dll`，从 `build\native_assets\windows\dart_quickjs.dll` 或 `.dart_tool\hooks_runner\shared\dart_quickjs\**\dart_quickjs.dll` 补入。
5. 重建 zip 后核对：目录 `LastWriteTime`、zip `LastWriteTime`、文件数量、zip 大小、`simple_live_app.exe` SHA256、zip SHA256。
