import { resolve } from 'node:path'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: {
    alias: {
      '@shared': resolve(__dirname, 'src/shared'),
      '@main': resolve(__dirname, 'src/main'),
      '@renderer': resolve(__dirname, 'src/renderer/src')
    }
  },
  test: {
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
    environment: 'node',
    // UI 用例在文件顶部写 `// @vitest-environment jsdom` 逐个切换，
    // 主进程 / 扫描器用例默认就是 node，两者共用一份配置。
    globals: false,
    testTimeout: 60_000,
    hookTimeout: 60_000,
    // 扫描器用例会读本机真实 Agent 目录，串行跑避免 I/O 抖动让断言不稳定。
    fileParallelism: false,
    pool: 'forks'
  }
})
