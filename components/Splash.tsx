// Animated logo shown when the app opens. Pure CSS: it plays over the first page
// and fades itself out, so it never delays loading. Shown once per visit; the
// inline script marks later loads in the same tab so it is skipped.
export const splashScript = `try{var k='classi-splash';if(sessionStorage.getItem(k))document.documentElement.classList.add('nosplash');else sessionStorage.setItem(k,'1')}catch(e){}`;

export function Splash() {
  return (
    <div className="splash" aria-hidden="true">
      <div className="splash-mark">
        <svg viewBox="0 0 64 64">
          <rect className="sp-tile" width="64" height="64" rx="16" />
          <path className="sp-c" d="M41.3 20.7A16 16 0 1 0 41.3 43.3" pathLength={100} />
          <circle className="sp-dot" cx="45" cy="32" r="4.5" />
        </svg>
        <span className="sp-ring" />
      </div>
      <b className="sp-word">Classi</b>
      <span className="sp-tag">كل التعليم في مكان واحد</span>
    </div>
  );
}
