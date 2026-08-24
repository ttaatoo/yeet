import { createFileRoute } from '@tanstack/react-router'
import { HomePage } from '@/components/home-page'
import { homeCopy } from '@/lib/home-copy'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { fetchLatestRelease } from '@/lib/release'

/** English landing page. Other languages live at `/$lang`. */
export const Route = createFileRoute('/')({
  component: Home,
  // Fetched per request (SSR). A download is shown only when GitHub has Yeet.zip.
  loader: () => fetchLatestRelease(),
  staleTime: 5 * 60 * 1000,
  head: () => {
    const copy = homeCopy(DEFAULT_LANGUAGE)
    return {
      meta: [
        { title: copy.title },
        { name: 'description', content: copy.description },
      ],
    }
  },
})

function Home() {
  return <HomePage lang={DEFAULT_LANGUAGE} release={Route.useLoaderData()} />
}
