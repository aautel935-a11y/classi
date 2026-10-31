"use client";

// Shown when a page cannot be built (for example the database is briefly unreachable). Errors are never cached,
// so trying again usually works.
export default function PageError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="wrap">
      <div className="section" role="alert">
        <h1>تعذّر فتح الصفحة</h1>
        <p className="muted">حدث خطأ مؤقت في الاتصال. حاول مرة أخرى بعد لحظات.</p>
        <button className="btn" onClick={() => reset()}>حاول مرة أخرى</button>
      </div>
    </div>
  );
}
