# 命名决策：Findio

日期：2026-11-15
决策：产品名改为 **Findio**，中文名取消（品牌位只留英文名，不再有副标题）。
查重原始记录见 [改名查重-Findio](改名查重-Findio.md)（阶段 0，只读）。

## 1. 查重事实

| 项 | 事实 | 判定 |
| --- | --- | --- |
| Google Play | `Findio: GPS phone tracker`，开发者 Fortunex Limited，2026-10-28 更新，育儿类畅销榜第 9 | **同名产品在运营**（手机定位） |
| `findio.app` | 2026-03-14 注册，GoDaddy，Cloudflare NS，落地页为西班牙语「Próximo lanzamiento」+ 订阅表单 | **已注册且有人在做同名产品（预告阶段）** |
| `findio.io` | 2023-07-02 注册，Registrar.eu，HTTP 只返回 `nginx/1.30.6` 默认页 | 已注册但无站点 |
| `findio.com` | 2004-09-03 注册，Register.com，本机 HTTP/HTTPS 均无法建立连接 | 已注册，站点内容未确认 |
| GitHub 用户名 | `github.com/findio` 已被个人账号（Sergey Baganov，2023-04 注册，9 个作业/试验仓库）占用 | 占用，但不是同名产品 |
| GitHub 仓库 | `yunyu697/findio` API 返回 404 | 可创建 |
| GitHub 全站 | `findio in:name` 21 个，最高 13★（Spotify 搜索玩具，2022-12 后未更新） | 无运营中的下载/搜索类产品 |
| Chrome / Edge / AMO | 均未出现精确同名扩展 | 可用 |
| npm / PyPI / crates.io | 三个注册表 `findio` 均 404 | 可用 |

## 2. 结论：接受同名不同域

- 本产品是 **Windows 桌面文件定位工具**（本地索引 + 全局热键 + 键盘直达），分发渠道是 GitHub Release 与 Windows 安装包；
  Google Play 上的同名产品是 Android 手机 GPS 定位应用，平台、渠道与品类均不重叠。
- 三个域名后缀均已被注册，`findio.app` 还有人在做预告页；**不自建同名主域名**，更新源继续走
  `https://github.com/yunyu697/findio/releases/latest/download/latest.json`。
- GitHub 用户名无法注册同名账号，不影响仓库与 Release 使用。
- 风险已知并接受：搜索「Findio」会命中手机定位 App；**发布说明必须写明「与同名手机定位 App 无关」**。

## 3. 改名范围与保留项

改动：

- 产品名、窗口标题、托盘提示、关于页、设置页、README 与全部 docs：Pathleap → Findio；中文名全部删除。
- 程序集名与命名空间：`Findio.Shared` / `Findio.Service` / `Findio.UI` / `Findio.ReleaseTool`；解决方案 `Findio.sln`。
- 安装包与产物名：`Findio-<版本>-win-x64.zip`、`Findio-<版本>-win-x64-setup.exe`。
- 应用标识符：Inno Setup `AppId` 换为新 GUID `{847ED305-ED44-4C67-8538-940E88EDA53B}`。
  旧版与新版的卸载项互不覆盖，本机旧安装需用旧卸载器单独卸载；不写迁移逻辑。
- 安装目录 `%LOCALAPPDATA%\Programs\Findio`（所有用户安装为 `Program Files\Findio`）、开始菜单与卸载项显示名 `Findio`。
- 注册表安装范围 `HKCU/HKLM\Software\Findio`。
- 计划任务名 `Findio-Elevated-<SID>`。
- 用户数据根 `%LOCALAPPDATA%\Findio`；环境变量 `FINDIO_DATA_ROOT`、`FINDIO_UPDATE_MIRROR`。
- 索引文件扩展名 `C.plidx` → `C.fidx`（附加索引 `extras.fidx`）。`pl` 是旧名缩写，且无存量用户，
  直接改扩展名；**升级后首次启动会重建一次索引**，不读旧 `.plidx`。
- 更新源 `yunyu697/findio`；CI 签名密钥 secret 名改为 `FINDIO_SIGNING_KEY`。

保留不动：

- 图标资源内容（`Findio.ico`、标记 PNG 的像素与矢量数据不变，仅随文件名改名）。
- 签名私钥与客户端内置公钥（`ReleaseSigning.cs` 的 `publicKeyBase64` 未改一个字符）。
- 快捷键、索引格式版本、配置字段名（只改目录与扩展名，不改 JSON 结构）。

## 4. 需要仓库外配合的一次性动作

1. GitHub 仓库改名为 `findio`（或新建后迁移），远程地址同步；已发 tag 与历史提交保留旧名，不改写。
2. 仓库 Secret `PATHLEAP_SIGNING_KEY` 改名为 `FINDIO_SIGNING_KEY`，密钥内容不变。
3. 本机旧安装用自带卸载器卸载并清理残留（清单见 [1.2.0-发布说明](1.2.0-发布说明.md)）。
