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
export const PAY_LABEL: Record<string, string> = { bit: "Bit", cash: "نقداً", card: "بطاقة ائتمان", installments: "3 دفعات", package: "من الرزمة" };

export type IconName =
  | "home" | "search" | "cal" | "chat" | "user" | "person" | "users" | "building" | "monitor" | "play"
  | "star" | "check" | "pin" | "back" | "plus" | "shield" | "grid" | "list" | "clock" | "bell" | "logout";

export type Owner = { id: string; name: string; town: string; rating: number; reviews_count: number; photo_url?: string | null; logo_url?: string | null };
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
  auto_confirm?: boolean;
  allow_weekly?: boolean;
  trial_price?: number | null;
  package_enabled?: boolean;
  package_size?: number | null;
  package_price?: number | null;
  teacher_id: string | null;
  institute_id: string | null;
  subject: { id: number; name: string } | null;
  level: { id: number; name: string } | null;
  teacher: Owner | null;
  institute: Owner | null;
  course_teacher: { id: string; name: string } | null;
};

export const OFFERING_SELECT =
  "id,type,title,active,moderation_hidden,auto_confirm,allow_weekly,trial_price,package_enabled,package_size,package_price,places,price,seats,schedule_note,start_date,sessions_count,lessons_count,minutes,teacher_id,institute_id," +
  "subject:subjects(id,name),level:levels(id,name)," +
  "teacher:teachers!offerings_teacher_id_fkey(id,name,town,rating,reviews_count,photo_url)," +
  "institute:institutes(id,name,town,rating,reviews_count,logo_url)," +
  "course_teacher:teachers!offerings_course_teacher_id_fkey(id,name)";

export const ownerOf = (o: Offering): Owner => (o.teacher ?? o.institute)!;
export const ownerName = (o: Offering) => (o.teacher ? `أ. ${o.teacher.name}` : o.institute!.name);

export function navFor(role: Role) {
  if (role === "teacher") return "teacher" as const;
  if (role === "institute") return "institute" as const;
  return "student" as const;
}

export const ownerPhoto = (o: Offering) => (o.teacher ? o.teacher.photo_url : o.institute?.logo_url) ?? null;

/** Each subject gets a glyph a teacher would write on the board, and its own colour. */
export const SUBJECT_LOOK: Record<string, { glyph: string; ink: string; tint: string }> = {
  "رياضيات": { glyph: "∑", ink: "#1E2F6E", tint: "#E3E8F7" },
  "إنجليزي": { glyph: "Aa", ink: "#8A3B12", tint: "#F7E3D6" },
  "عبري": { glyph: "אב", ink: "#0F5E5A", tint: "#D8EFEC" },
  "عربي": { glyph: "ض", ink: "#7A2E52", tint: "#F3DDE8" },
  "فيزياء": { glyph: "F=ma", ink: "#2F5D1E", tint: "#E1EED8" },
  "كيمياء": { glyph: "H₂O", ink: "#6B4E00", tint: "#F6EBC8" },
  "أحياء": { glyph: "DNA", ink: "#1E6B3A", tint: "#DAF0E1" },
  "حاسوب": { glyph: "</>", ink: "#333A56", tint: "#E6E8EF" },
  "بسيخومتري": { glyph: "800", ink: "#5B2A86", tint: "#ECE1F5" },
};
export const subjectLook = (name?: string | null) => SUBJECT_LOOK[name ?? ""] ?? { glyph: "✎", ink: "#1E2F6E", tint: "#E3E8F7" };
