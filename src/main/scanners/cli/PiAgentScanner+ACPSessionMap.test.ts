import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CleanPrefs } from '@main/core/scanner'
import { cleanEmptyProjectDirectories, pruneACPSessionMap } from './PiAgentScanner+ACPSessionMap'

/**
 * `pi-acp/session-map.json` 裁剪 + 空项目目录回收的独立用例。
 *
 * 主体行为已由 `PiAgentScanner+ContextMode.test.ts` 端到端覆盖，
 * 这里把两个纯函数的边界情况单独钉住。
 */

const prefHome = realpathSync(mkdtempSync(join(tmpdir(), 'pi_acp_home_')))
const originalHome = process.env['HOME']
process.env['HOME'] = prefHome

let root = ''

function dir(...segments: string[]): string {
  const path = join(root, ...segments)
  mkdirSync(path, { recursive: true })
  return path
}

function write(path: string, content: string): string {
  const full = path.startsWith('/') ? path : join(root, path)
  mkdirSync(dirname(full), { recursive: true })
  writeFileSync(full, content, 'utf8')
  return full
}

function exists(path: string): boolean {
  return existsSync(path)
}

function readSessions(mapPath: string): string[] {
  const parsed = JSON.parse(readFileSync(mapPath, 'utf8')) as { sessions?: Record<string, unknown> }
  return Object.keys(parsed.sessions ?? {}).sort()
}

beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'pi_acp_')))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
  CleanPrefs.patch({ cleanEmptyProjectFolders: true })
})

afterAll(() => {
  if (originalHome === undefined) delete process.env['HOME']
  else process.env['HOME'] = originalHome
  rmSync(prefHome, { recursive: true, force: true })
})

describe('pruneACPSessionMap · 回写保真度', () => {
  it('保留 version 等无关字段，sessions 之外的键不动', () => {
    const alive = write(join(root, 'a.jsonl'), '{}')
    const dead = write(join(root, 'b.jsonl'), '{}')
    const map = write(
      join(root, 'session-map.json'),
      JSON.stringify({
        version: 1,
        updatedAt: '2026-09-01T00:00:00Z',
        sessions: {
          gone: { sessionId: 'gone', sessionFile: dead },
          stay: { sessionId: 'stay', sessionFile: alive }
        }
      })
    )

    pruneACPSessionMap(map, new Set(['gone']), new Set([dead]))

    const parsed = JSON.parse(readFileSync(map, 'utf8')) as Record<string, unknown>
    expect(parsed['version']).toBe(1)
    expect(parsed['updatedAt']).toBe('2026-09-01T00:00:00Z')
    expect(readSessions(map)).toEqual(['stay'])
  })

  it('回写是原子的：不留 .tmp 残骸，且内容是格式化过的 JSON', () => {
    const alive = write(join(root, 'a.jsonl'), '{}')
    const map = write(
      join(root, 'session-map.json'),
      JSON.stringify({ sessions: { x: { sessionId: 'x', sessionFile: alive } } })
    )

    pruneACPSessionMap(map, new Set(['other']), new Set([join(root, 'nope.jsonl')]))
    // 走的是「无 stale → 不重写」路径，内容逐字不变
    expect(readFileSync(map, 'utf8')).toBe(
      JSON.stringify({ sessions: { x: { sessionId: 'x', sessionFile: alive } } })
    )
    expect(exists(`${map}.tmp`)).toBe(false)
  })
})

describe('cleanEmptyProjectDirectories · 空项目目录回收', () => {
  it('没有 .jsonl 的项目目录被回收，仍有会话的保留', () => {
    const sessionsDir = dir('agent', 'sessions')
    const empty = dir('agent', 'sessions', '--Users-empty--')
    write(join(empty, 'leftover.txt'), 'x') // 非会话文件不算数
    const alive = dir('agent', 'sessions', '--Users-alive--')
    write(join(alive, '2026-09-01T00-00-00-000Z_sid.jsonl'), '{}')

    cleanEmptyProjectDirectories(sessionsDir)

    expect(exists(empty)).toBe(false)
    expect(exists(alive)).toBe(true)
  })

  it('开关关闭时一个目录都不删', () => {
    const sessionsDir = dir('agent', 'sessions')
    const empty = dir('agent', 'sessions', '--Users-empty--')

    CleanPrefs.patch({ cleanEmptyProjectFolders: false })
    cleanEmptyProjectDirectories(sessionsDir)

    expect(exists(empty)).toBe(true)
  })

  it('目录本身不存在时静默返回', () => {
    expect(() => cleanEmptyProjectDirectories(join(root, 'nope'))).not.toThrow()
  })
})
