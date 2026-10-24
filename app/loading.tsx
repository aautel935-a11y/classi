// Shown instantly while the next page loads, so taps feel immediate.
export default function Loading() {
  return (
    <div className="wrap" aria-busy="true" aria-label="جارٍ التحميل">
      <div className="section">
        <div className="sk" style={{ height: 28, width: "55%" }} />
        <div className="sk" style={{ height: 96 }} />
        <div className="sk" style={{ height: 96 }} />
        <div className="sk" style={{ height: 96 }} />
      </div>
    </div>
  );
}
