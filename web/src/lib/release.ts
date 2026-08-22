export type Release = { version: string; minSystem: string; zip: string }

const REPO = 'ttaatoo/kero'
const GITHUB_API_LATEST = `https://api.github.com/repos/${REPO}/releases/latest`
const ZIP_ASSET = 'Kerox.zip'
/** Matches MACOSX_DEPLOYMENT_TARGET on the kero target in kero.xcodeproj. */
const MIN_SYSTEM = '15.6'

export const GITHUB_URL = `https://github.com/${REPO}`
export const X_URL = 'https://x.com/localhost_4173'

// The tap is this repo (`Casks/kerox.rb`), not `ttaatoo/homebrew-kero`, so the
// tap URL has to be named. `--cask` is required: the same tap also has a formula.
export const BREW_COMMAND =
  'brew tap ttaatoo/kero https://github.com/ttaatoo/kero && brew install --cask ttaatoo/kero/kerox'

// Shown only if GitHub Releases can't be reached; kept current so downloads still work.
const FALLBACK: Release = {
  version: '0.1.50',
  minSystem: MIN_SYSTEM,
  zip: `${GITHUB_URL}/releases/download/v0.1.50/${ZIP_ASSET}`,
}

type GitHubRelease = {
  tag_name?: string
  assets?: { name?: string; browser_download_url?: string }[]
}

/**
 * Read the newest GitHub Release that ships Kerox.zip. Packaged Kerox has no
 * Sparkle feed; the site must not read releases.kero.sh (that is official Kero).
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
        'User-Agent': 'kerox-web',
      },
      signal: AbortSignal.timeout(2500),
      // The site runs as a Cloudflare Worker; cache the payload at the edge so we
      // don't refetch on every render (matches its own 5-min max-age). `cf` isn't
      // part of the DOM RequestInit type, hence the cast.
      cf: { cacheTtl: 300, cacheEverything: true },
    } as RequestInit & { cf: { cacheTtl: number; cacheEverything: boolean } })
    if (!res.ok) return FALLBACK
    const parsed: unknown = await res.json()
    if (parsed === null || typeof parsed !== 'object') return FALLBACK
    return parseGitHubRelease(parsed) ?? FALLBACK
  } catch {
    return FALLBACK
  }
}
