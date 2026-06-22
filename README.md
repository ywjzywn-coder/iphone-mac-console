# iPhone Mac Console

把旧 iPhone / Android 手机变成 Mac 的无线触控板、键盘和快捷控制台。  
手机打开一个网页，就能在同一 Wi‑Fi 下控制 Mac。

![GitHub Release](https://img.shields.io/github/v/release/ywjzywn-coder/iphone-mac-console?label=release)
![Platform](https://img.shields.io/badge/platform-macOS%20%2B%20mobile%20browser-black)
![License](https://img.shields.io/badge/license-open--source-blue)

## 功能

- 手机浏览器直接使用，无需安装手机 App
- 支持 iPhone、iPad、Android
- 触控板：移动、点击、双击、长按拖拽
- 手势：两指滚动/右键/前进后退/缩放，三指/四指切换桌面
- 手机键盘输入到 Mac
- 快捷命令面板
- PWA：可添加到手机桌面
- 本地局域网运行，不走云端

## 工作方式

```text
手机 / 平板浏览器                 Mac 本地 Host
┌──────────────────┐   Wi‑Fi   ┌────────────────────┐
│ 触控板 · 键盘 · 控制台 │ ───────▶ │ 本地服务器 + CGEvent │
└──────────────────┘           └────────────────────┘
```

Mac 负责启动本地服务，手机访问 Mac 给出的局域网地址。所有控制指令都在本地网络内传输。

## 下载

从 Releases 下载最新版本：

https://github.com/ywjzywn-coder/iphone-mac-console/releases/latest

推荐下载：

```text
iphone-mac-console-mac-app-v0.1.0.zip
```

解压后运行 macOS 菜单栏 App。

## 从源码运行

```sh
git clone https://github.com/ywjzywn-coder/iphone-mac-console.git
cd iphone-mac-console
npm start
```

然后用手机打开终端打印的地址，例如：

```text
http://192.168.x.x:8787
```

输入 Mac 端显示的 6 位配对码即可连接。

## macOS 权限

如果手机已连接，但 Mac 光标不动或不能输入，请打开：

```text
系统设置 > 隐私与安全性 > 辅助功能
```

允许运行 Host 的 App 或终端，然后重启服务。

## 常用手势

| 手势 | 动作 |
|---|---|
| 一指移动 | 移动光标 |
| 一指点击 / 双击 | 左键 / 双击 |
| 一指长按拖动 | 拖拽窗口、文件或滑块 |
| 两指拖动 | 滚动 |
| 两指停按 | 右键 |
| 两指左右滑 | 前进 / 后退 |
| 两指捏合 | 缩放 |
| 三指上滑 / 下滑 | Mission Control / App Expose |
| 三指或四指左右滑 | 切换桌面 |

## 开发

```sh
swift build
node --check server.js
node --check public/app.js
```

## 说明

- `.runtime/`、`certs/`、`.build/`、`dist/`、`.codex/` 等本地环境和构建产物不会提交到仓库
- 摄像头和麦克风功能暂不包含，本项目专注于「手机控制 Mac」
