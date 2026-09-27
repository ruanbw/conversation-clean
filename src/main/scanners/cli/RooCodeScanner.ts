import type { ScannerOptions } from '@main/core/scanner'
import { ClineScanner } from './ClineScanner'

/**
 * Roo Code 扫描器。
 *
 * Roo Code 的会话存储与 Cline 完全同构（同一个扩展的不同 ID），扫描逻辑复用 `ClineScanner`，
 * 只覆写分类名、环境变量与默认目录。
 *
 * 数据布局（`ROO_CODE_HOME` 可覆盖）：
 * ```
 * …/globalStorage/rooveterinaryinc.roo-cline/
 *   tasks/<taskId>/…
 *   checkpoints/<taskId>/…
 *   state/taskHistory.json
 *   cache/
 * ```
 */
export class RooCodeScanner extends ClineScanner {
  override readonly category = 'rooCode' as const

  constructor(options: ScannerOptions = {}) {
    super(options)
  }

  protected override get envVarName(): string {
    return 'ROO_CODE_HOME'
  }

  protected override get defaultStorageSegments(): readonly string[] {
    return [
      'Library',
      'Application Support',
      'Code',
      'User',
      'globalStorage',
      'rooveterinaryinc.roo-cline'
    ]
  }
}
