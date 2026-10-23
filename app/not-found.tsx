import Link from "next/link";

export default function NotFound() {
  return (
    <div className="wrap">
      <div className="empty stack">
        <h1>الصفحة غير موجودة</h1>
        <p>ربما حُذف هذا العرض أو تغيّر الرابط.</p>
        <Link className="btn" href="/">العودة للرئيسية</Link>
      </div>
    </div>
  );
}
