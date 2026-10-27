/** "How do I book?" — three steps, folded by default. */
export function HowToBook() {
  return (
    <details className="howto">
      <summary>كيف أحجز حصة؟</summary>
      <ol>
        <li><b>اختر المعلم أو الدورة</b><span>ابحث بالمادة والمرحلة، وافتح العرض لترى السعر والتقييمات والفيديو التعريفي.</span></li>
        <li><b>اختر الموعد</b><span>المواعيد الظاهرة فارغة ويمكن حجزها، والرمادية محجوزة. للدورات اختر «تسجيل».</span></li>
        <li><b>احجز وادفع</b><span>ادفع عبر Bit (الرقم يظهر في «جدولي» بعد الحجز) أو نقداً للمعلم. يصلك تذكير قبل الحصة.</span></li>
      </ol>
      <p className="small muted">عندك سؤال قبل الحجز؟ راسل المعلم من صفحته، أو اضغط زر «؟» أسفل الشاشة للتحدث مع إدارة Classi.</p>
    </details>
  );
}
