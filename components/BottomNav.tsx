"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Icon } from "./Icon";
import type { IconName } from "@/lib/types";

const NAVS: Record<"student" | "teacher" | "institute", [string, string, IconName][]> = {
  student: [["/", "الرئيسية", "home"], ["/search", "بحث", "search"], ["/schedule", "جدولي", "cal"], ["/notifications", "الإشعارات", "bell"], ["/account", "حسابي", "user"]],
  teacher: [["/teach", "لوحتي", "grid"], ["/teach/new", "عرض جديد", "plus"], ["/notifications", "الإشعارات", "bell"], ["/account", "حسابي", "user"]],
  institute: [["/manage", "لوحة المعهد", "building"], ["/manage/new-course", "دورة جديدة", "plus"], ["/notifications", "الإشعارات", "bell"], ["/account", "حسابي", "user"]],
};

export function BottomNav({ kind, unread }: { kind: keyof typeof NAVS; unread: number }) {
  const path = usePathname();
  const items = NAVS[kind];
  const active =
    items.map(([href]) => href).filter((h) => (h === "/" ? path === "/" : path === h || path.startsWith(h + "/"))).sort((a, b) => b.length - a.length)[0] ?? "";
  return (
    <nav className="bar" dir="rtl" aria-label="التنقل">
      <div className="in">
        {items.map(([href, label, icon]) => (
          <Link key={href} href={href} aria-current={href === active ? "page" : undefined} className="navitem">
            <span className="navicon">
              <Icon name={icon} />
              {icon === "bell" && unread > 0 && <i className="num">{unread}</i>}
            </span>
            <span>{label}</span>
          </Link>
        ))}
      </div>
    </nav>
  );
}
