import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './styles/tokens.css'
import './styles/global.css'

/**
 * 渲染进程入口。
 *
 * 本文件只做两件事：找到 `#root` 并把根组件挂上去，以及引全局样式。
 *
 * `window.api` 桥不在这里初始化 —— 它由 preload 在任何 React 代码跑起来之前
 * 就用 `contextBridge` 挂好（见 `src/preload/index.ts`）。渲染进程开着
 * `contextIsolation`，拿不到 `ipcRenderer` 本身，只能用它暴露的那几个白名单函数；
 * 所以这里若再去探测/兜底 `window.api`，等于把一道刻意的隔离重新捅开。
 */

const container = document.getElementById('root')
if (!container) {
  throw new Error('找不到 #root 挂载点')
}

createRoot(container).render(
  <StrictMode>
    <App />
  </StrictMode>
)
