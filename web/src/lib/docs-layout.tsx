import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { GITHUB_URL } from '@/lib/release'

/** The changelog is generated from CHANGELOG.md, so it has no translation. */
const NAV_LABELS = {
  en: { home: 'Home', changelog: 'Changelog', download: 'Download' },
  zh: { home: '首页', changelog: '更新日志', download: '下载' },
} as const

/** Chrome shared by every docs page: the yeet wordmark plus links back to the site. */
export function docsLayoutOptions(lang: string): BaseLayoutProps {
  const labels = NAV_LABELS[lang as keyof typeof NAV_LABELS] ?? NAV_LABELS.en
  const home = lang === DEFAULT_LANGUAGE ? '/' : `/${lang}`

  return {
    githubUrl: GITHUB_URL,
    // The site has no light mode, so a light/dark toggle would be a control
    // that does nothing.
    themeSwitch: { enabled: false },
    nav: {
      url: home,
      title: (
        <span className="inline-flex items-center gap-2">
          <img
            src="/yeet-icon.png"
            alt=""
            width={100}
            height={100}
            className="size-5 rounded-[5px] border border-zinc-600"
          />
          <span className="font-mono font-bold tracking-[0.02em]">yeet</span>
        </span>
      ),
    },
    links: [
      { text: labels.home, url: home, active: 'url' },
      { text: labels.changelog, url: '/changelog', active: 'url' },
      { type: 'button', text: labels.download, url: home, active: 'none' },
    ],
  }
}
