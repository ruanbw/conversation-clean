import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './styles/tokens.css'
import './styles/global.css'

/**
 * 渲染进程入口。
 *
 * 对应 Swift 版 `ConversationCleanApp.swift` 的 `WindowGroup { ContentView() }`：
 * 挂载根组件，并把 `window.api` 桥的初始化交给 `App` 内的 effect。
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
