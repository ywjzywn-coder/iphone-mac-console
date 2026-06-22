# iPhone Mac Console

把旧 iPhone / Android 手机变成 Mac 的本地控制台：可以当触控板、键盘、快捷命令面板使用。

适合场景：

- Mac mini / 台式 Mac 离屏控制
- 手机临时当触控板和键盘
- 局域网内用手机控制 Mac
- 旧手机改造成桌面控制器

## 功能特性

- 手机浏览器直接打开，无需安装 App
- 支持 iPhone / iPad / Android
- 支持 PWA，可添加到手机桌面
- 一指移动光标、点击、双击
- 一指长按拖拽窗口/文件/滑块
- 两指滚动、两指停按右键
- 两指左右滑动浏览器/应用前进后退
- 两指捏合缩放
- 三指/四指切换桌面、调度中心、App Expose
- 手机端键盘输入到 Mac
- 快捷命令面板
- 指针速度、滚动速度可调
- 横屏模式、全屏模式
- Android 性能模式
- macOS 窗口吸附预览
- 配对码保护，避免局域网内误连

## 快速开始

### 方式一：Node 版本

```sh
npm start
```

启动后，终端会打印一个局域网地址，例如：

```text
http://192.168.x.x:8787
```

用手机浏览器打开这个地址，然后输入 Mac 终端显示的 6 位配对码。

### 方式二：双击启动

在 Finder 里双击：

```text
start-mac-console.command
```

### 方式三：macOS 菜单栏 App

构建并启动常驻菜单栏版本：

```sh
./script/build_and_run.sh
```

构建后的 App 位于：

```text
dist/Mac Console Host.app
```

菜单栏 App 可以：

- 启动/重启本地控制服务器
- 显示当前配对码
- 复制或打开手机访问地址
- 打开辅助功能权限设置
- 安装/移除开机自启动 LaunchAgent

运行状态会写入：

```text
.runtime/status.json
```

## Android PWA / HTTPS

Android 如果想显示真正的「安装 App」选项，通常需要 HTTPS：

```sh
npm run start:https
```

然后打开终端打印的：

```text
https://...:8788
```

项目会生成本地证书到 `certs/localhost-cert.pem`。如果手机不信任证书，需要把证书安装并设为可信，或者使用可信 HTTPS 隧道。

iPhone/iPad 通常可以在局域网 HTTP 下直接「添加到主屏幕」。

## 安装到手机桌面

### iPhone / iPad

1. 用 Safari 打开 Mac 打印出来的地址
2. 点分享按钮
3. 选择「添加到主屏幕」

### Android

1. 用 Chrome 打开地址
2. 点右上角菜单
3. 选择「添加到主屏幕」或「安装应用」

## 手势说明

- 一指移动：移动 Mac 光标
- 一指点击：左键单击
- 一指双击：左键双击
- 一指长按后移动：拖拽窗口、文件、滑块或选中文本
- 两指停按：右键
- 两指拖动：滚动
- 两指水平滑动：浏览器/应用后退或前进（`Command + [` / `Command + ]`）
- 两指捏合：缩放（`Command + +` / `Command + -`）
- 三指上滑：调度中心 Mission Control
- 三指下滑：App Expose
- 三指或四指左右滑：切换桌面
- 浮动 `...` 抽屉：全屏、指针速度、滚动速度、默认横屏、拖拽锁定、Android 性能模式

## 手机端设置

- **指针速度**：`0.30x` 到 `4x`
- **滚动速度**：`0.8x` 到 `8x`
- **自然滚动**：切换滚动方向
- **默认横屏**：更适合手机横放当触控板
- **拖拽锁定**：降低长按拖拽时误松手
- **Android 性能模式**：减少 Android Chrome 上的抖动和卡顿
- **轻微震动反馈**：触控反馈

## macOS 权限

如果手机界面已连接，但 Mac 光标不动、不能点击或输入，需要打开权限：

```text
系统设置 > 隐私与安全性 > 辅助功能
```

允许运行服务器的终端 App，或允许菜单栏 App。然后重启服务。

## 不支持或近似支持的功能

- Force Click / 压感：手机浏览器无法提供 Mac 触控板压力数据
- 真正的惯性滚动：可以发送滚动增量，但无法完全模拟 Apple 触控板硬件动量
- Launchpad 捏合：macOS 没有稳定公开 API 让网页变成系统触控板
- 显示桌面的完整手势形状：手机浏览器无法稳定识别类似拇指+多指展开的复杂形状
- 旋转手势：系统级用途有限，浏览器暴露也不稳定
- 三指拖移系统设置：网页无法读取 macOS 辅助功能里的三指拖移设置
- 伪装成真实 Apple Trackpad：macOS 没有公开 API 让 Web App 变成硬件触控板

## 安全说明

- 服务只监听本地网络
- 每次启动会生成新的配对码和 session token，除非手动设置 `PAIR_CODE`
- `.runtime/`、`certs/`、`.build/`、`dist/`、`.codex/` 等本地环境和构建产物不会提交到 GitHub
- 摄像头和麦克风功能暂时交给 DroidCam / Camo / OBS 等专用工具，本项目专注于「手机控制 Mac」

## 开发验证

```sh
swift build
node --check server.js
node --check public/app.js
```

## 项目结构

```text
Sources/MacConsoleHost/   macOS 本地输入和菜单栏 Host
public/                   手机端网页/PWA
server.js                 Node 本地服务器
native/                   原生控制相关文件
script/                   构建和启动脚本
tools/                    辅助检查工具
```
