# FUJIFILM Apeos 2350 NDA — macOS 打印驱动

给 **富士胶片 Apeos 2350 NDA**（2150 N 同系列）在 macOS 上用的 CUPS 驱动。
官方没有 macOS 驱动，本工程自己补上这一环。

> **English** — A CUPS driver that lets macOS print to the **FUJIFILM Apeos 2350 NDA**
> (2150 N family). The device has no page description language: FUJIFILM's own
> manual lists only **HBPL (Host Based Print Language)**, so the vendor ships a
> Windows-only, host-rendered driver and macOS cannot use PostScript or PCL.
> This project fills the gap with a CUPS filter that reuses the system's own
> `cgpdftoraster` and encodes the result as HBPL v2 over raw port 9100.
> Verified against real hardware on macOS 27 (arm64): single and multi page,
> page order, long/short-edge duplex, odd-page duplex tails, collated copies.

- 目标机型：FUJIFILM Apeos 2350 NDA / 2150 N 系列（主机端渲染机型）
- 实测环境：macOS 27.0.1 (26A434) arm64，CUPS 2.3.4
- 实测打印机：192.168.1.100，RAW 9100
- 状态：**已在真机上验证出纸**

---

## 1. 为什么没有现成驱动可用

先说结论：**这台机器没有页面描述语言**，不能靠"通用 PostScript/PCL 驱动"糊过去。

官方文档（富士胶片中文使用说明书 GM1051C3-4 第 199–200 页「规格」）逐字写明：

| 项目 | 官方值 |
|---|---|
| 页面记述语言 | **HBPL (Host Based Print Language)** |
| 网络协议 | **以太网: TCP/IP（lpd、端口 9100）** |
| 支持的操作系统 | 仅 Windows 10 / 8.1 / Server 2012–2019 |

配套证据：

- 官方彩页的选配件只有纸盒 / 手送纸盘 / 储物柜 —— **没有 PostScript 组件、没有 PCL 组件**。
- 拆开官方 Windows 驱动包（`ffa2350ndahb221120w636izh.exe`），内部路径是
  `Software/HB/amd64/.../ffhl1a64.inf`，含主机端渲染器 `ffhl1arender.exe`，
  包里**没有任何 PCL / PostScript minidriver**。`HB` = Host Based。
- 说明书另一处明文：`不支持 AirPrint 和 Mopria`。

所谓 HBPL，就是"页面由电脑渲染好、以压缩位图传给打印机"，打印机只负责把点阵打出来。
所以**驱动就是那个渲染器**——这正是本工程要补的东西。

### 关于 192.168.1.100 上的 IPP / AirPrint

实测该地址 **631 端口是开的**，IPP 还会回报很漂亮的
`ipp-features-supported = airprint-1.3`、`urf-supported = W8,SRGB24,RS600,...`，
Web 后台的 AirPrint 页面也显示"已启用"。**但这是一层空壳**：

- 从不通过 Bonjour 广播 `_ipp._tcp`（只广播 `_printer._tcp` 和 `_pdl-datastream._tcp`）
- `Print-Job` 返回 `successful-ok` 却不创建作业，响应体只有 102 字节，
  缺少 IPP 规范强制要求的 `job-uri` / `job-id` / `job-state`
- 作业一旦创建就永远停在 `pending-held` + `job-state-reasons = job-data-insufficient`
- 设备自报身份是占位值 `MFG:Test;MDL:Printer;CMD:URF;`，四个 CMYK 墨盒都是 "0%"
- HTTP 头是 `Server: HTTP server`、`Date: Tue Dec 4 11:45:05 2007`（时钟未设置），
  表单走 `/goform/`，且表单 action 叫 `form_prtsvr...`（print server）

即：**该 IP 上的网络打印服务是一套通用嵌入式固件，其 IPP/AirPrint 通路没有接到打印引擎上。**
真正的打印通路只有 **RAW 9100 / LPD**，数据必须是 HBPL。

---

## 2. 驱动怎么做的

HBPL 没有公开规范，但开源项目 **foo2zjs** 里有逆向出来的实现
（`foo2hbpl2`，HBPL **v2**，JBIG 编码位图），本工程复用它，并补上 macOS 缺的那一段。

```
应用程序
   │  PDF
   ▼
cgpdftoraster          ← macOS 系统自带滤镜
   │  CUPS raster (application/vnd.cups-raster, 600dpi, 8bpp 连续调灰度)
   ▼
rastertohbpl           ← 本工程的滤镜（单个自包含二进制）
   │   1. 解析 CUPS raster
   │   2. Floyd–Steinberg 误差扩散加网（在本滤镜内完成，见下）
   │   3. 位打包 + 编码为 HBPL v2（JBIG 压缩）
   ▼
HBPL 数据流（PJL 头 + JP/PS/PE 记录）
   │
   ▼
socket://192.168.1.100:9100   ← CUPS socket 后端
```

**全部依赖都是系统自带的**：不需要 Ghostscript、不需要 Homebrew、不需要 Rosetta。

### 为什么滤镜是"一个自包含二进制"

- macOS 的 `/usr/libexec/cups/filter` 在 SIP 下只读，**不能**往里放东西。
  CUPS 支持 PPD 里写**绝对路径**的滤镜，所以放在 `/Library/Printers/...`（厂商驱动也是这么做的）。
- macOS 的 CUPS 会用沙箱跑滤镜，读取白名单含 `/Library`、`/usr/bin`、`/private/tmp`，
  但**不含** `/usr/local` 和 `/opt/homebrew`。因此依赖 Homebrew 版 Ghostscript 的方案在服务端走不通。
- 本滤镜把 HBPL 编码器（`foo2hbpl2.c`）直接编进同一个二进制，
  运行期**不 fork/exec 任何子进程**，彻底避开沙箱的 exec 限制。

### 加网放在哪一层：为什么改成滤镜内误差扩散

HBPL 只吃 1-bit 位图，所以"灰度 → 黑白点阵"的加网必须在主机侧完成。
最早的两套方案都试过：滤镜自己用 8×8 Bayer 有序抖动（规则网点、观感差），
以及让 `cgpdftoraster` 直接输出 1-bit（Apple 的加网）。当时选了后者，但用真实
照片和扫描件打印后暴露了一个明显缺陷：

> **`cgpdftoraster` 的 1-bit 加网是一个 64×64 像素固定阈值模板的平铺。**
> 600 dpi 下 64 px = **2.71 mm**，于是照片、扫描件的平滑区域会显现
> 2.7 mm 周期的"小正方形色块"，色调在 1 mm 尺度上也起伏不均
> （第 19 页实测：1 mm 块色调误差 RMS 2.25/255、最大 14/255；
> 加网图案在 64 px 间隔上的自相关 0.99）。
> 全局墨量其实很准——问题出在"局部色调 + 可见周期性"上。

现在的做法：PPD 让 `cgpdftoraster` 输出 **8-bit 连续调灰度**
（`cupsColorSpace 3` + `cupsBitsPerColor 8`），由本滤镜做**蛇形
Floyd–Steinberg 误差扩散**，再打包成 1-bit 交给 HBPL 编码器。
误差扩散没有固定周期，局部色调被保留，照片上不再出现方块/网纹：

| 指标（第 19 页，600 dpi，与 8-bit 参考比） | 旧：cgpdftoraster 1-bit | 新：8-bit + FS |
|---|---|---|
| 1 mm 块色调误差 RMS（8-bit 级） | 2.25 | **0.49** |
| 1 mm 块色调误差最大值 | 13.9 | **5.1** |
| 64 px（2.71 mm）图案自相关 | 0.99 | **≈0（无周期）** |
| HBPL 数据量（31 页扫描件） | 26.8 MB | **22.4 MB** |

数据量反而变小，是因为误差扩散的随机噪声比规则模板更好被 JBIG 压缩。
代价是中间 raster 由 4 MB/页变成 32 MB/页（A4 600 dpi），但只在本机滤镜管道
里流动、不落盘，实测 31 页整本 13 s 处理完。

**对文字的影响**：`cgpdftoraster` 在 8 bpc 下对矢量文字/线条输出的仍是
0/255 二值，所以这部分逐像素不变；扫描件里的抗锯齿文字用误差扩散反而更干净
（纸白区杂点 824 px → 37 px）。

**实测分辨率极限**（600 dpi / 1-bit，真机出纸确认）：

| 棋盘格间距 | 结果 |
|---|---|
| 2 px = 0.085 mm | 糊成均匀灰块 |
| 4 px = 0.17 mm | 糊成均匀灰块 |
| **8 px = 0.34 mm** | **起，能清楚分辨** |
| 16 px / 32 px | 清楚 |

灰度值仍被忠实保留：2px 棋盘格在加网前平均黑度 41%，加网后实测 41.8%。

这不是缺陷，是 1-bit 输出的物理规律——它用空间分辨率换灰阶层次，
图案周期小于一个加网单元（≈0.34 mm）时只能还原成等效灰度。

### 对 foo2hbpl2 的两处本地修改

上游 `src/foo2hbpl2.c` 在这台机器上有两个缺陷，都已就地修正，并在源码里用
`LOCAL PATCH` 注释标明：

| 位置 | 上游行为 | 造成的问题 | 修正 |
|---|---|---|---|
| `start_doc()` | 写死 `@PJL SET DUPLEX=OFF`，从不发 `ON`，也没有 `BINDING` | **自动双面完全失效**。打印机永远按单面处理，但分页逻辑仍会旋转偶数页，于是"双面打印"出来是两张单面纸、且第 2 页倒着 | 按 `-d` 参数发出 `@PJL SET DUPLEX=ON` + `@PJL SET BINDING=LONGEDGE/SHORTEDGE`，与同门 `foo2qpdl`/`foo2hiperc` 的写法一致 |
| `pbm_pages()` | 长边双面时对偶数页做 180° `rotate_bytes_180` | 这台机器**自己就会**按 `BINDING` 翻转背面，叠加后成了双重旋转，背面上下颠倒 | 默认关闭该旋转；确有需要的机型可加 `-DHBPL2_ROTATE_BACKS` 恢复上游行为 |

两处改动都经过真机验证。**双面实现要点**：CUPS 光栅头里 `Duplex` 只是开关，
长边/短边由**另一个独立字段 `Tumble`** 表示（0=长边，1=短边）；滤镜把这一对映射成
foo2hbpl2 的 `-d2`（长边）/ `-d3`（短边），最终发出
`@PJL SET DUPLEX=ON` + `@PJL SET BINDING=LONGEDGE|SHORTEDGE`。
只读 `Duplex` 而忽略 `Tumble` 会让两种双面都变成长边——这个坑已经踩过并修掉。

### 份数与逐份打印

打印机的 `@PJL SET COPIES=n` 是**逐页复制**语义：两页文档打 2 份，出来是 `1,1,2,2`。
这正是"不分份"该有的样子，但**不是**"打两份完整的"该有的样子。

所以逐份由主机侧实现：滤镜把整个页序在数据流里**重复 N 遍**，并告诉打印机
`COPIES=1`；不分份时才交给打印机的 `COPIES=n`。PPD 的 `*DefaultCollate` 默认为
**True**，也就是默认逐份。

双面时每份末尾会补一张**空白页**（仅当每份页数为奇数）：打印机把相邻两页配成
一张纸的两面，不补齐的话第 2 份会和第 1 份串页配对。

### 一个必须注意的 CUPS 安全策略

CUPS **拒绝执行非 root 所有的滤镜**。用普通用户身份安装会得到：

```
E [Job 48] 文件"/private/tmp/apeos2350/rastertohbpl"有不安全权限（0100755/uid=501/gid=0）。
E [Job 48] Unable to start filter "/tmp/apeos2350/rastertohbpl" - Invalid argument.
D [Job 48] Stopping job because the scheduler could not execute a filter.
```

所以 `install.sh` **必须用 sudo 运行**，把滤镜装成 `root:wheel 0755`。

---

## 3. 安装

```sh
cd apeos2350-driver
sudo ./install.sh              # 只装驱动和队列
sudo ./install.sh --test       # 装完顺便打一张测试页
```

可选参数：

| 参数 / 变量 | 作用 |
|---|---|
| `--test` | 安装后打印 `tools/testpage.pdf` |
| `--clean-legacy` | 顺便删除旧的、不可能工作的 `FUJIFILM_Apeos_2350_NDA__4B_58_3A_` 队列 |
| `IP=...` | 打印机地址（默认 192.168.1.100） |
| `QUEUE=...` | 队列名（默认 `Apeos_2350_HBPL`） |

安装后：

```sh
lpstat -p Apeos_2350_HBPL -l        # 看队列
lp -d Apeos_2350_HBPL 文件.pdf      # 打印
lpoptions -d Apeos_2350_HBPL        # 设为默认打印机
sudo ./uninstall.sh                 # 卸载
```

卸载：

```sh
sudo ./uninstall.sh
```

---

## 4. 分发给别人

### 构建安装包

```sh
./dist/build-pkg.sh            # 产物在 dist/out/
VERSION=1.8 ./dist/build-pkg.sh
```

| 产物 | 用途 |
|---|---|
| `Apeos2350NDA-HBPL-<ver>.pkg` | 双击即可安装的安装包 |
| `Apeos2350NDA-HBPL-<ver>.zip` | pkg + `INSTALL.txt` + `GPL-2.0.txt`，发给别人用这个 |
| `Apeos2350NDA-HBPL-<ver>-src.tar.gz` | 对应源码，**GPLv2 要求随二进制一起提供** |

二进制是 **universal（arm64 + x86_64）**，Intel Mac 也能用。

### 安装包做了什么

1. 把 `rastertohbpl` 装进 `/Library/Printers/FUJIFILM/Apeos2350/`，
   并强制 `chown root:wheel`（`pkgbuild --ownership recommended` 已设为 root，
   postinstall 再兜一次底——CUPS 会拒绝执行非 root 所有的滤镜）；
2. 把 PPD 装进 `/Library/Printers/PPDs/Contents/Resources/`；
3. postinstall 用 Bonjour 在局域网里找这台打印机（它广播
   `_pdl-datastream._tcp`），建立队列 `Apeos_2350_HBPL`；
   找不到就退回默认地址，队列照样建好，之后可以改。

### 对方需要知道的事

- 双击 `.pkg`，输入管理员密码；或
  `sudo installer -pkg Apeos2350NDA-HBPL-1.0.pkg -target /`
- **未签名的包会被 Gatekeeper 拦下**：右键点 pkg → 打开 → 再点打开；
  或 系统设置 → 隐私与安全性 → 拉到底 → "仍要打开"
- 必须在同一局域网。打印机地址不对时：

  ```sh
  sudo /Library/Printers/FUJIFILM/Apeos2350/set-printer-address.sh <打印机IP>
  ```

  这个地址会记在 `printer-address.conf` 里，重装时优先于 Bonjour 发现。
- 安装日志：`/var/log/apeos2350-install.log`
- 打印机休眠时 9100 端口可能不应答，安装脚本会警告但仍然完成安装。

### 如果你有 Apple Developer ID，可以签名+公证

```sh
productsign --sign "Developer ID Installer: 你的名字 (TEAMID)" \
            Apeos2350NDA-HBPL-1.0.pkg Apeos2350NDA-HBPL-1.0-signed.pkg
xcrun notarytool submit Apeos2350NDA-HBPL-1.0-signed.pkg \
      --keychain-profile <profile> --wait
xcrun stapler staple Apeos2350NDA-HBPL-1.0-signed.pkg
```

签名并公证后，对方双击就能装，不会看到安全警告。

### GPLv2 合规

本驱动链接了 foo2hbpl2 与 JBIG-KIT，**整体是 GPLv2**。分发二进制时必须同时
提供对应源码（`-src.tar.gz`），或给出获取源码的书面承诺；安装包里也放了
`COPYING.txt` 全文。转发时请把 `-src.tar.gz` 一起带上。

## 5. 自己重新编译

工程是自包含的，`src/` 里已经包含所需的全部源码：

```sh
./build.sh          # 产出 bin/rastertohbpl
```

| 文件 | 说明 |
|---|---|
| `src/rastertohbpl.c` | 本工程的 CUPS 滤镜：CUPS raster（8-bit 灰度）→ 误差扩散加网 → PBM → 调用 HBPL 编码器 |
| `src/foo2hbpl2.c`, `src/hbpl.h` | HBPL v2 编码器（Rick Richardson，GPLv2） |
| `src/jbig*.c`, `src/jbig*.h` | JBIG-KIT（Markus Kuhn，GPLv2）—— HBPL v2 用 JBIG 压位图 |
| `ppd/FUJIFILM-Apeos-2350-NDA-HBPL.ppd` | 驱动 PPD，`@FILTER@` 由安装脚本替换为实际路径 |

---

## 6. 排查

**打印无反应 / 作业停住**

```sh
lpstat -p Apeos_2350_HBPL -l        # 队列告警
lpstat -o Apeos_2350_HBPL           # 排队中的作业
tail -50 /var/log/cups/error_log    # CUPS 日志（需先开 debug：cupsctl --debug-logging）
```

**验证"渲染出来到底长什么样"**（不出纸也能看）：

```sh
cupsfilter -p /Library/Printers/PPDs/Contents/Resources/...  # 或用队列 PPD
lp -d Apeos_2350_HBPL -o media=A4 文件.pdf
```

或者手工跑一遍滤镜，并把加网后的位图直接导出成 PBM（不用解码 HBPL）：

```sh
# 1) 得到 8-bit 灰度 CUPS raster（用队列/PPD 渲染）
cupsfilter -p /Library/Printers/PPDs/Contents/Resources/"FUJIFILM Apeos 2350 NDA HBPL.ppd" \
           -m application/vnd.cups-raster 文件.pdf > /tmp/x.ras

# 2) 跑滤镜；RASTERTOHBPL_PBM_DUMP 会把最终 1-bit 位图另存一份
RASTERTOHBPL_PBM_DUMP=/tmp/x.pbm \
  ./bin/rastertohbpl 1 "$USER" "test" 1 "" /tmp/x.ras > /tmp/x.hbpl

# /tmp/x.pbm 是标准 PBM P4，可直接用看图软件打开；
# /tmp/x.hbpl 就是原样发给打印机的 HBPL 数据流
```

`RASTERTOHBPL_PBM_DUMP` 只在手动排查时用；CUPS 正常调度时不会设置它。
如果 raster 本身就是 1-bit（例如改用别的 PPD），滤镜会原样透传、不再加网。

**判断"是驱动坏了还是加网正常"**：打 `tools/diagnostic.pdf`，第 4 节是间距递减的
棋盘格扫描；2px/4px 是灰块、8px 起能分辨，就是在正常工作。

**打印作业显示"已完成"但纸上什么都没出来**：先看打印机自己报的状态。它的 IPP 端点
虽然不能打印（见 §1），但**状态是真实的**：

```sh
ipptool -t -T 8 ipp://<打印机IP>:631/ipp/print tools/apeos-capabilities.test \
  | grep -i "printer-state"
```

出现 `media-jam-error` 就是卡纸（双面走纸路径最容易卡，双面要求纸重 60–90 g/m²）。
清掉卡纸即可——注意 **CUPS 侧仍会显示作业"已完成"**，别被它误导。
出现 `toner-low-report` 只是碳粉将尽的常规提示。

**打印机休眠**：Apeos 会休眠，休眠时 9100 端口可能无响应。从面板唤醒或先开一下它的 Web 后台。

---

## 7. 已知限制

- **细节极限约 0.34 mm**：比这更细的图案（0.1 mm 级棋盘格等）会被还原成等效灰度
  而不是图案本身，原因见 §2 的实测数据。
- **8-bit 中间 raster 变大**：A4 600dpi 一页约 32 MB（1-bit 时约 4 MB），
  只在 `cgpdftoraster → rastertohbpl` 的管道里流动、不落盘；
  发给打印机的 HBPL 数据流体积反而比旧的 1-bit 有序加网小约 16%。
- **误差扩散的固有限制**：极端平坦的纯矢量平色块在 600 dpi 下可能出现
  4 px 级的轻微纹理（正常照片/扫描件不会）；如果以后遇到，可在加网前加
  ±1 LSB 抖动或做阈值吸附（`src/rastertohbpl.c` 的 `dither_row_fs()`）。
- **照片/扫描件里的方块不再由加网产生**：如果换成误差扩散后仍看到 1 mm 级
  方形色块，那是源文件自身的 JPEG 8×8 块（200 dpi 扫描件约 1.02 mm），
  驱动层无法消除。
- **实测覆盖**：A4 单面 600dpi（含 3 页文档，**页序正确、第 1 页在最上**）、
  A4 长边双面（DuplexNoTumble）、A4 短边双面（DuplexTumble）、
  **奇数页双面收尾**（3 页文档双面，最后一张单面）、
  **2 份逐份打印**（2 页文档 × 2 份 → `1,2,1,2`）——**均已真机验证**。
- **未实测**：A3 及其他纸型。官方规格给出双面上限 A3 / 11×17"、下限 A5、
  纸重 60–90 g/m²（手送纸盘可到 110 g/m²）、自定义尺寸不支持双面；
  这些组合 PPD 里虽然可选，但没有实测过。
- PPD 里的 Duplex 依赖 `@PJL SET DUPLEX/BINDING`；若某台机器忽略这两个 PJL 变量，
  表现会是"选双面仍出两张单面纸"（参见 §2 的本地修改说明）。
- 页边距按 4mm 可打印区设置（取自设备 IPP 自报的 `media-col-database`），
  若实际有偏移需要微调 PPD 里的 `*ImageableArea`。
- 这台设备的"网络打印服务"是通用嵌入式固件（见 §1），如果哪天它被换掉或者打印机的
  USB 链路断了，表现会是"作业发出去但什么都不出"。
- `tools/` 下是本工程排查时用的探针脚本和测试页，正常使用不需要它们。

---

## 8. 变更记录

### 1.8 (2026-10) — 修复照片打印出现"小正方形色块 / 颜色不均匀"

- **问题**：照片页、扫描件（尤其是浅色、平滑渐变的区域）打印后可见约
  2.7 mm 周期的方形色块，色调也不均匀。
- **原因**：驱动原先让 `cgpdftoraster` 输出 1-bit；它的 1-bit 加网是一个
  64×64 px 固定阈值模板的平铺（600 dpi 下 64 px = 2.71 mm）。模板的周期性
  在纸上表现为"小正方形色块"，同时 1 mm 尺度的局部色调误差可达 14/255。
- **修复**：PPD 改为输出 8-bit 连续调灰度（`cupsBitsPerColor 8`），
  由 `rastertohbpl` 做蛇形 Floyd–Steinberg 误差扩散后再打包成 1-bit。
  1 mm 块色调误差 RMS 2.25 → 0.49，64 px 周期结构消失；矢量文字/线条
  逐像素不变；发给打印机的 HBPL 数据量还小了约 16%。
- **真机验证**：安装后打印同一份 31 页扫描件（含瓷砖照片页），
  2.7 mm 方块消失，照片与扫描背景色调均匀（2026-10-20，Apeos 2350 NDA）。
- **升级**：重新运行 `sudo ./install.sh`（PPD 和滤镜都需要更新；
  只换其一会出现 8-bit PPD 配旧滤镜 = 旧滤镜按 8-bit 输入的路径处理，仍能打印但
  仍是旧加网/或旧 PPD 配新滤镜 = 1-bit 透传，也是旧观感）。
- 排查手段：`RASTERTOHBPL_PBM_DUMP=/tmp/x.pbm ./bin/rastertohbpl ...`
  可导出最终 1-bit 位图（见 §6）。

---

## 9. 许可

- `src/rastertohbpl.c`：本工程，**GPLv2**（因为它链接了 GPLv2 的 foo2hbpl2/JBIG-KIT）。
- `src/foo2hbpl2.c`、`src/hbpl.h`：出自 [foo2zjs](https://github.com/OpenPrinting/foo2zjs)，
  © Rick Richardson，GPLv2。
- `src/jbig*.{c,h}`：JBIG-KIT，© Markus Kuhn，GPLv2。

商业分发前请自行确认许可条款。
