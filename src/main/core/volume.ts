import { statfsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { homedir } from 'node:os'
import { dirname, join, parse } from 'node:path'
import type { VolumeInfo } from '@shared/types'

/**
 * 宿主卷的容量与已用量。
 *
 * 口径：总容量 = `statfs` 的 `blocks * bsize`，已用 = 总容量 − `bavail * bsize`。
 * 用 `bavail` 而不是 `bfree`：`bavail` 不含 root 保留块，比真实可用量更保守，
 * 方向上安全 —— 宁可少报可用量。（Finder「可用空间」用的是更宽的口径，
 * 已扣掉 purgeable；`statfs` 没有对应字段，这段差异是已知且可接受的。）
 *
 * **为什么必须读真值**：原型里的 `VOL = {cap:994GiB, used:912GiB}` 是写死的演示数字。
 * 拿它去承诺用户「清理后 91.750% 已用」是在拿一条不存在的卷撒谎。
 * 读不到就返回 `null`，UI 整块不渲染 —— 宁可少一节，也不能用假分母编占比。
 *
 * 结果进程内缓存：卷容量在一次应用生命周期里不会变，而确认弹层每开一次就问一次。
 */
let cached: VolumeInfo | null | undefined

export function currentVolumeInfo(): VolumeInfo | null {
  if (cached !== undefined) return cached
  cached = readVolumeInfo()
  return cached
}

/** 测试与「用户换了外置盘」场景用：丢弃缓存，下次重新读盘。 */
export function __resetVolumeCache(): void {
  cached = undefined
}

function readVolumeInfo(): VolumeInfo | null {
  const home = homedir()
  let stats: ReturnType<typeof statfsSync>
  try {
    stats = statfsSync(home)
  } catch {
    return null
  }

  const capacity = Number(stats.blocks) * Number(stats.bsize)
  const available = Number(stats.bavail) * Number(stats.bsize)
  // 读不到有效值时宁可返回 null，也不要造一个假分母。
  if (!Number.isFinite(capacity) || capacity <= 0) return null
  if (!Number.isFinite(available) || available <= 0 || available > capacity) return null

  const used = capacity - available
  if (used <= 0) return null

  const mountPath = findMountPoint(home, stats) ?? parse(home).root
  return {
    name: volumeName(mountPath),
    mountPath,
    capacity,
    used
  }
}

/** 判定两个 statfs 结果是否描述同一个文件系统。 */
function sameVolume(
  a: ReturnType<typeof statfsSync>,
  b: ReturnType<typeof statfsSync>
): boolean {
  return a.type === b.type && a.bsize === b.bsize && a.blocks === b.blocks
}

/**
 * 沿路径向上找出真正的挂载点。
 *
 * macOS 的家目录常在 `/Users/...`，而它其实位于 APFS 容器共享的 Data 卷
 * （`/System/Volumes/Data`）。逐级向上试探，遇到 statfs 描述变化的目录就是挂载点。
 * 找不到就返回 `parse(path).root`，比猜一个好。
 */
function findMountPoint(path: string, target: ReturnType<typeof statfsSync>): string | null {
  let current = path
  for (let depth = 0; depth < 16; depth += 1) {
    const parent = dirname(current)
    // dirname('/') === '/'，再往上没有意义了。
    if (parent === current) return current
    try {
      const parentStats = statfsSync(parent)
      if (!sameVolume(parentStats, target)) return current
    } catch {
      return current
    }
    current = parent
  }
  return current
}

let nameCache = new Map<string, string>()

/**
 * 卷名。
 *
 * 根卷 `/` 的卷名（「Macintosh HD」之类）在文件系统层面取不到：
 * 挂载点是 `/`，末段是空串。`diskutil info -plist <mount>` 能拿到，但那是 spawn 一次进程。
 * 所以先看挂载点末段（`/Volumes/Macintosh HD` → `Macintosh HD`，最准），
 * 末段不可用（根卷 `/`）时才 spawn 一次 `diskutil`，并且结果按挂载点缓存。
 */
function volumeName(mountPath: string): string {
  const cachedName = nameCache.get(mountPath)
  if (cachedName !== undefined) return cachedName

  const leaf = mountPath.split('/').filter(Boolean).pop()
  let name = leaf !== undefined && leaf.length > 0 ? leaf : ''
  if (name.length === 0) {
    name = diskutilVolumeName(mountPath)
  }
  if (name.length === 0) name = '本机磁盘'

  nameCache.set(mountPath, name)
  return name
}

function diskutilVolumeName(mountPath: string): string {
  try {
    const out = execFileSync('diskutil', ['info', '-plist', mountPath], {
      encoding: 'utf8',
      timeout: 2000,
      stdio: ['ignore', 'pipe', 'ignore']
    })
    // plist 里是 `<key>Volume Name</key>\n<string>Macintosh HD</string>`。
    const match = /<key>Volume Name<\/key>\s*<string>([^<]+)<\/string>/.exec(out)
    return match?.[1]?.trim() ?? ''
  } catch {
    return ''
  }
}

/** 导出给 `deleteAllOfCategory` 之外的地方复用：某个路径所在卷的剩余容量（字节）。 */
export function availableCapacity(path: string): number | null {
  try {
    const stats = statfsSync(path)
    return Number(stats.bavail) * Number(stats.bsize)
  } catch {
    return null
  }
}

/** 供测试注入：直接塞一个卷信息，跳过真实读盘。 */
export function __setVolumeForTests(info: VolumeInfo | null): void {
  cached = info
}

export { join }
