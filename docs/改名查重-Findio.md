# 改名查重：Findio（阶段 0，2026-11-15，只读）

> 目标名：Findio（中文名取消）。本轮只查不改：无代码、无安装包、无仓库设置改动。
> 判定口径按用户要求：域名只认 RDAP 注册局结果，不用 DNS 解析结果推断；同名产品在运营或开发中则停下。

## 1 GitHub

| 项 | 结果 | 判断 |
| --- | --- | --- |
| 仓库 `yunyu697/findio` | API 返回 404 | 可创建 |
| 用户 `github.com/findio` | 已存在：Sergey Baganov，2023-04 注册，9 个公开仓库（作业/试验类），最后更新 2023-04 | 占用，但不是同名产品 |
| 全站同名仓库 | `findio in:name` 共 21 个；最高星为 `csteinmetz1/findio`（13★，Spotify 搜索玩具，最后推送 2022-12）；其余 0–1★，含 `Findio/*` 的作业仓库、`Findio/test` 等 | 无正在运营的下载/搜索类产品 |

说明：GitHub 用户名与仓库名不阻塞发布，只是不能再注册同名用户；如需要可继续用 `yunyu697/findio`。

## 2 域名（RDAP 注册局查询）

| 域名 | RDAP 结果 | 站点内容 | 判断 |
| --- | --- | --- | --- |
| findio.com | 已注册：2004-09-03 注册，2027-09-03 到期，Register.com，`clientTransferProhibited`，2026-08-04 最后变更，NS 为 zoneedit | 本机 HTTP/HTTPS 均无法建立连接（证书/链路失败） | **已注册，站点内容未确认**（无法排除有人在用） |
| findio.io | 已注册：2023-07-02 注册，2027-07-02 到期，Registrar.eu，NS 为 kinetic.cloud，`clientTransferProhibited` | HTTP 只返回 `nginx/1.30.6` 默认页 | **已注册但无站点** |
| findio.app | 已注册：2026-03-14 注册，2027-03-14 到期，GoDaddy，Cloudflare NS，四类 client\*Prohibited | 落地页为西班牙语「Próximo lanzamiento（即将上线）」+ 订阅表单 | **已注册且有人在做同名产品（预告阶段）** |

## 3 三家浏览器商店（精确同名）

| 商店 | 结果 | 判断 |
| --- | --- | --- |
| Chrome Web Store | 搜索页与外部检索均未出现名为 Findio 的扩展（只有 Findify/Fontio 等近似名） | 未发现精确同名 |
| Microsoft Edge Add-ons | 搜索页未出现精确同名扩展 | 未发现精确同名 |
| Firefox AMO | API `q=findio` 返回 939 条模糊匹配，逐条名称中无精确 `Findio` | 未发现精确同名 |

## 4 包管理器

| 注册表 | 结果 | 判断 |
| --- | --- | --- |
| npm | `registry.npmjs.org/findio` → 404 | 可用 |
| PyPI | `pypi.org/pypi/findio/json` → 404 | 可用 |
| crates.io | `api/v1/crates/findio` → 404 | 可用 |

## 5 额外发现（不在用户清单内，但属同名产品）

- **Google Play：`Findio: GPS phone tracker`**，开发者 Fortunex Limited，2026-10-28 更新，育儿类畅销榜第 9，仍在运营。
  这是目前唯一确认「同名产品在运营」的证据，类别是手机定位，与桌面搜索不同域。

## 6 结论：停在阶段 0

按用户「有同名产品在运营或正在开发的，单独标出来并停下等用户决定」的要求，本轮**不改名**。两个需要用户拍板的点：

1. `findio.app` 已在做同名产品（预告页，西班牙语市场），且 `findio.com` 已被长期持有（站点内容本机无法确认）。
2. Google Play 已有运营中的同名 App「Findio: GPS phone tracker」。

可选路径（等用户选）：

- A. 接受同名不同域：继续用 Findio，发布说明里明确「与同名手机定位 App 无关」，域名走自建/不使用三后缀；
- B. 换一个主名（保留 Findio 作为内部代号），重新按本流程查重；
- C. 先只改窗口标题与安装包名，不动域名/商店占位，等商标与域名谈拢再全量改名。

未做：GitHub 用户名/仓库改名、域名注册、商店占位、任何代码或产物改动。
