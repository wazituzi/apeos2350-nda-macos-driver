富士胶片 Apeos 2350 NDA —— macOS 打印驱动
==========================================

安装包：Apeos2350NDA-HBPL-<版本>.pkg（如 1.2）


这个驱动解决什么问题
--------------------

Apeos 2350 NDA / 2150 N 系列没有页面描述语言。富士胶片官方说明书
（GM1051C3-4 第 199-200 页）写明它的打印语言是

    HBPL (Host Based Print Language)

也就是说页面必须由电脑渲染成压缩位图再传给打印机，打印机本身不会解释
PostScript 或 PCL。官方只为它提供 Windows 驱动，所以 macOS 上装不上任何
现成驱动。

本安装包补上这一环：它安装一个 CUPS 滤镜，用 macOS 系统自带的
cgpdftoraster 把 PDF 渲染成光栅，再编码成 HBPL 送到打印机的 9100 端口。

    应用 → PDF → cgpdftoraster（系统自带）→ CUPS 光栅
         → rastertohbpl（本驱动）→ HBPL → socket://<打印机>:9100


安装
----

1. 双击 Apeos2350NDA-HBPL-<版本>.pkg，按提示安装（需要管理员密码）。

   如果 macOS 提示"来自身份不明的开发者"：
     - 在"访达"里右键点这个 pkg → 选"打开" → 再点"打开"；
     - 或者：系统设置 → 隐私与安全性 → 拉到底 → "仍要打开"。

   也可以直接在终端里装：

       sudo installer -pkg Apeos2350NDA-HBPL-<版本>.pkg -target /

2. 安装脚本会自动在局域网里用 Bonjour 找到这台打印机，并建立打印队列
   Apeos_2350_HBPL。

   如果打印机当时在休眠或不在线，队列仍会建好（指向默认地址
   192.168.1.100），之后再纠正即可：

       sudo /Library/Printers/FUJIFILM/Apeos2350/set-printer-address.sh <打印机IP>

   安装日志在 /var/log/apeos2350-install.log。


使用
----

在任意应用里按 ⌘P，打印机列表里选：

    FUJIFILM Apeos 2350 NDA (HBPL driver)

或者用命令行：

    lp -d Apeos_2350_HBPL 文件.pdf          # 打印
    lpoptions -d Apeos_2350_HBPL            # 设为默认打印机
    lp -d Apeos_2350_HBPL -o media=A3 文件.pdf
    lp -d Apeos_2350_HBPL -o Duplex=DuplexNoTumble 文件.pdf

支持的选项：A3/A4/A5/B5/Letter/Legal/8.5x13 纸张、单双面、逐份、600dpi。


卸载
----

    sudo lpadmin -x Apeos_2350_HBPL
    sudo rm -rf /Library/Printers/FUJIFILM/Apeos2350
    sudo rm -f "/Library/Printers/PPDs/Contents/Resources/FUJIFILM Apeos 2350 NDA HBPL.ppd"


常见问题
--------

问：打出来是空白 / 完全没反应？
答：先确认打印机没在休眠，并且和它在同一网段：

       nc -z -G 3 <打印机IP> 9100 && echo OK

   不通就先用 set-printer-address.sh 重新指向正确地址。

问：灰阶看起来是密密麻麻的点？
答：正常。600dpi 单色激光只有"打点/不打点"两种状态，灰阶靠加网模拟。
   加网单元约 0.34mm，所以比这更细的图案（比如 0.1mm 的棋盘格）会被
   还原成等效灰度而不是图案本身，这是 1-bit 加网的物理限制。

问：这张驱动能打印 A3 或双面吗？
答：选项里有，但只在 A4 单面 600dpi 上做过真机验证。


许可
----

- 滤镜本体 rastertohbpl：GPLv2
- HBPL v2 编码器 foo2hbpl2（Rick Richardson）：GPLv2
- JBIG-KIT（Markus Kuhn）：GPLv2

完整源码随驱动一起分发，见 /Library/Printers/FUJIFILM/Apeos2350/ 和
安装包同目录的 GPL-2.0.txt。因为整体是 GPLv2，转发给别人时请一并保留
源码与许可证。
