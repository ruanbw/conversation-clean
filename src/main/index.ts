import { app, BrowserWindow, Menu, nativeTheme, shell } from 'electron'
import { join } from 'node:path'
import { registerIpcHandlers } from './ipc'

/**
 * Electron 主进程入口。
 *
 * 对应 Swift 版 `ConversationClean/ConversationCleanApp.swift` + `ContentView.swift` 的窗口配置：
 * 隐藏标题栏、红绿灯浮在自有背景上、窗口底色取设计系统的 `--bg`。
 */

/** 与 `src/renderer/src/styles/tokens.css` 的 `--bg` 保持一致。 */
const WINDOW_BG = '#fafafb'
const WINDOW_BG_DARK = '#18181b'

function createWindow(): BrowserWindow {
  const dark = nativeTheme.shouldUseDarkColors

  const window = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 960,
    minHeight: 560,
    show: false,
    backgroundColor: dark ? WINDOW_BG_DARK : WINDOW_BG,
    // 隐藏标题栏：红黄绿浮在自有背景上，与 Swift 版 hiddenTitleBar + 手搓三栏一致。
    // trafficLightPosition 把三个按钮推到 78pt 处，给自绘品牌区让位。
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 16, y: 18 },
    // 侧栏要显示真实 app 图标与文件目录，禁止任何外链跳转。
    webPreferences: {
      // electron-vite 在 `type: module` 下把 preload 编译成 ESM（`index.mjs`），
      // ESM preload 需要 `sandbox: false` 才能工作 —— 两者必须同时改。
      preload: join(__dirname, '../preload/index.mjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  })

  window.once('ready-to-show', () => window.show())

  // 外链一律走系统浏览器，窗口本身永远不导航到外部地址。
  window.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
    return { action: 'deny' }
  })

  const devServerUrl = process.env['ELECTRON_RENDERER_URL']
  if (devServerUrl) {
    void window.loadURL(devServerUrl)
  } else {
    void window.loadFile(join(__dirname, '../renderer/index.html'))
  }

  return window
}

app.whenReady().then(() => {
  // macOS 菜单栏：这是一个单窗口工具，默认菜单（带 DevTools 的 Edit 菜单）不该出现。
  // 需要调试时用 ⌥⌘I / ⌥⌘C，electron-vite dev 已注册。
  if (process.platform === 'darwin') {
    Menu.setApplicationMenu(
      Menu.buildFromTemplate([
        {
          label: app.getName(),
          submenu: [
            { role: 'about' },
            { type: 'separator' },
            { role: 'hide' },
            { role: 'hideOthers' },
            { role: 'unhide' },
            { type: 'separator' },
            { role: 'quit' }
          ]
        },
        {
          label: '编辑',
          submenu: [
            { role: 'copy' },
            { role: 'selectAll' },
            { type: 'separator' },
            {
              label: '开发者',
              accelerator: 'Alt+Cmd+I',
              click: () => BrowserWindow.getFocusedWindow()?.webContents.toggleDevTools()
            }
          ]
        },
        {
          label: '窗口',
          submenu: [{ role: 'minimize' }, { role: 'zoom' }, { role: 'togglefullscreen' }]
        }
      ])
    )
  }

  registerIpcHandlers()
  createWindow()

  app.on('activate', () => {
    // macOS 惯例：点 Dock 图标时若没有窗口就再开一个。
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
