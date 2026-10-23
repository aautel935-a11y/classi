export type OfferingType = "private" | "group" | "course" | "recorded";
export type Place = "home" | "online" | "center";
export type Role = "guardian" | "student" | "teacher" | "institute" | "admin";

export const TYPES: Record<OfferingType, { name: string; icon: IconName; desc: string; unit: string }> = {
  private: { name: "درس خصوصي", icon: "person", desc: "معلم لك وحدك، بالساعة", unit: "للساعة" },
  group: { name: "مجموعة تقوية", icon: "users", desc: "مقاعد محدودة وسعر للطالب", unit: "للقاء" },
  course: { name: "دورة معهد", icon: "building", desc: "تسجيل في دورة كاملة", unit: "للدورة" },
  recorded: { name: "محتوى مسجّل", icon: "play", desc: "شاهد متى شئت", unit: "مرة واحدة" },
};
export const PLACES: Record<Place, string> = { home: "حضوري", online: "أونلاين", center: "في المعهد" };
export const TOWNS = ["باقة الغربية", "جت", "الطيبة", "الطيرة", "كفر قرع", "عرعرة", "أم الفحم", "زيمر", "قلنسوة", "كفر قاسم"];
export const PAY_LABEL: Record<string, string> = { bit: "Bit", cash: "نقداً", card: "بطاقة ائتمان", installments: "3 دفعات" };

export type IconName =
  | "home" | "search" | "cal" | "chat" | "user" | "person" | "users" | "building" | "monitor" | "play"
  | "star" | "check" | "pin" | "back" | "plus" | "shield" | "grid" | "list" | "clock" | "bell" | "logout";

export type Owner = { id: string; name: string; town: string; rating: number; reviews_count: number };
export type Offering = {
  id: string;
  type: OfferingType;
  title: string;
  places: Place[];
  price: number;
  seats: number | null;
  schedule_note: string | null;
  start_date: string | null;
  sessions_count: number | null;
  lessons_count: number | null;
  minutes: number;
  active?: boolean;
  teacher_id: string | null;
  institute_id: string | null;
  subject: { id: number; name: string } | null;
  level: { id: number; name: string } | null;
  teacher: Owner | null;
  institute: Owner | null;
  course_teacher: { id: string; name: string } | null;
};

export const OFFERING_SELECT =
  "id,type,title,active,places,price,seats,schedule_note,start_date,sessions_count,lessons_count,minutes,teacher_id,institute_id," +
  "subject:subjects(id,name),level:levels(id,name)," +
  "teacher:teachers!offerings_teacher_id_fkey(id,name,town,rating,reviews_count)," +
  "institute:institutes(id,name,town,rating,reviews_count)," +
  "course_teacher:teachers!offerings_course_teacher_id_fkey(id,name)";

export const ownerOf = (o: Offering): Owner => (o.teacher ?? o.institute)!;
export const ownerName = (o: Offering) => (o.teacher ? `أ. ${o.teacher.name}` : o.institute!.name);

export function navFor(role: Role) {
  if (role === "teacher") return "teacher" as const;
  if (role === "institute") return "institute" as const;
  return "student" as const;
}
