export type Release = {
  minSystem: string
  version?: string
  zip?: string
}

const REPO = 'ttaatoo/yeet'
const GITHUB_API_LATEST = `https://api.github.com/repos/${REPO}/releases/latest`
const ZIP_ASSET = 'Yeet.zip'
/** Matches MACOSX_DEPLOYMENT_TARGET on the yeet target in yeet.xcodeproj. */
const MIN_SYSTEM = '15.6'

export const GITHUB_URL = `https://github.com/${REPO}`
export const KERO_URL = 'https://github.com/egoist/kero'
export const CONTRIBUTING_URL = `${GITHUB_URL}/blob/main/CONTRIBUTING.md`

// The tap is this repo (`Casks/yeet.rb`), not `ttaatoo/homebrew-kero`, so the
// tap URL has to be named. `--cask` is required: the same tap also has a formula.
export const BREW_COMMAND =
  'brew tap ttaatoo/yeet https://github.com/ttaatoo/yeet && brew install --cask ttaatoo/yeet/yeet'

/** Shown when GitHub has no Yeet.zip — never invent a download URL. */
export const NO_RELEASE: Release = { minSystem: MIN_SYSTEM }

type GitHubRelease = {
  tag_name?: string
  assets?: { name?: string; browser_download_url?: string }[]
}

/**
 * Read the newest GitHub Release that ships Yeet.zip. Packaged Yeet has no
 * Sparkle feed; the site must not read releases.kero.sh (that is official Kero).
 * Returns null unless that exact asset exists — a tag without Yeet.zip is
 * not a public download.
 */
export function parseGitHubRelease(data: GitHubRelease): Release | null {
  const tag = data.tag_name?.trim() ?? ''
  const version = tag.startsWith('v') ? tag.slice(1) : tag
  if (!version) return null
  const zip = data.assets
    ?.find((asset) => asset.name === ZIP_ASSET)
    ?.browser_download_url?.trim()
  if (!zip) return null
  return { version, minSystem: MIN_SYSTEM, zip }
}

export async function fetchLatestRelease(): Promise<Release> {
  try {
    const res = await fetch(GITHUB_API_LATEST, {
      headers: {
        Accept: 'application/vnd.github+json',
        'User-Agent': 'yeet-web',
      },
      signal: AbortSignal.timeout(2500),
      // The site runs as a Cloudflare Worker; cache the payload at the edge so we
      // don't refetch on every render (matches its own 5-min max-age). `cf` isn't
      // part of the DOM RequestInit type, hence the cast.
      cf: { cacheTtl: 300, cacheEverything: true },
    } as RequestInit & { cf: { cacheTtl: number; cacheEverything: boolean } })
    if (!res.ok) return NO_RELEASE
    const parsed: unknown = await res.json()
    if (parsed === null || typeof parsed !== 'object') return NO_RELEASE
    return parseGitHubRelease(parsed) ?? NO_RELEASE
  } catch {
    return NO_RELEASE
  }
}
