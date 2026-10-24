import { Icon } from "@/components/Icon";

function youtubeId(url: string) {
  const m = url.match(/(?:youtu\.be\/|youtube\.com\/(?:watch\?(?:.*&)?v=|shorts\/|embed\/|live\/))([\w-]{6,15})/);
  return m?.[1] ?? null;
}

/** The teacher's short intro: embedded when it's YouTube, a button for other sites. */
export function IntroVideo({ url, name }: { url?: string | null; name: string }) {
  if (!url) return null;
  const yt = youtubeId(url);
  return (
    <div className="intro-video">
      <b className="small"><Icon name="play" /> تعرّف على {name}</b>
      {yt ? (
        <div className="video-frame">
          <iframe
            src={`https://www.youtube-nocookie.com/embed/${yt}?rel=0`}
            title={`فيديو تعريفي: ${name}`}
            loading="lazy"
            allow="accelerometer; encrypted-media; gyroscope; picture-in-picture; fullscreen"
            allowFullScreen
          />
        </div>
      ) : (
        <a className="btn ghost sm" href={url} target="_blank" rel="noopener noreferrer"><Icon name="play" />شاهد الفيديو التعريفي</a>
      )}
    </div>
  );
}
