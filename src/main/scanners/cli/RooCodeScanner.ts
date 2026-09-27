import type { ScannerOptions } from '@main/core/scanner'
import { ClineScanner } from './ClineScanner'

/**
 * Roo Code 扫描器。
 *
 * 源文件：`ConversationClean/Scanners/CLIAgents/RooCodeScanner.swift` —— 全文 13 行，
 * 是 `ClineScanner` 的子类，只覆写三处：分类、环境变量名、默认数据目录。
 * 两者的落盘结构完全一致（`tasks/<taskId>` + `checkpoints/<taskId>` + `state/taskHistory.json`），
 * 所以这里同样用继承表达，扫描 / 删除 / 索引同步的行为一行都不重写。
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
