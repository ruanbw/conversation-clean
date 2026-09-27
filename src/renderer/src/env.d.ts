/// <reference types="vite/client" />

import type { PreloadApi } from '../../preload/index'

declare global {
  interface Window {
    /**
     * preload 挂上来的主进程桥。渲染进程里**只能**通过它碰主进程能力，
     * 不要在渲染进程里 import 任何 `node:*` 或 `electron`。
     */
    api: PreloadApi
  }
}

export {}
