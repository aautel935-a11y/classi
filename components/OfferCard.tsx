import Link from "next/link";
import { Icon, Stars } from "./Icon";
import { PLACES, TYPES, ownerName, ownerOf, ownerPhoto, subjectLook, type Offering } from "@/lib/types";
import { Avatar } from "./Avatar";
import { shekel } from "@/lib/format";

export function TypeBadge({ type }: { type: Offering["type"] }) {
  return (
    <span className="badge">
      <Icon name={TYPES[type].icon} />
      {TYPES[type].name}
    </span>
  );
}

export function OfferCard({ o, taken, showOwner = true }: { o: Offering; taken?: number; showOwner?: boolean }) {
  const own = ownerOf(o);
  const full = o.seats != null && taken != null && taken >= o.seats;
  const look = subjectLook(o.subject?.name);
  return (
    <Link className="card offer" href={`/offer/${o.id}`} style={{ ["--ink" as string]: look.ink, ["--tint" as string]: look.tint }}>
      <div className="top">
        <div className="row" style={{ flexWrap: "wrap" }}>
          <TypeBadge type={o.type} />
          {full && <span className="badge bad">ممتلئ</span>}
        </div>
        <div className="price num">
          {shekel(o.price)} <small>{TYPES[o.type].unit}</small>
        </div>
      </div>
      <div className="offer-title">
        <span className="glyph" aria-hidden="true">{look.glyph}</span>
        <h3>{o.title}</h3>
      </div>
      {showOwner && (
        <div className="row small owner-line">
          <Avatar name={own.name} url={ownerPhoto(o)} size="sm" inst={!!o.institute} />
          <span>{ownerName(o)}</span>
          <span className="verified" title="موثّق">
            <Icon name="shield" />
          </span>
        </div>
      )}
      <div className="meta">
        <span>
          <Icon name="pin" />
          {own.town}
        </span>
        <span>
          <Icon name={o.places.includes("online") ? "monitor" : "home"} />
          {o.places.map((p) => PLACES[p]).join(" أو ")}
        </span>
        <Stars rating={own.rating} count={own.reviews_count} />
      </div>
      {o.seats != null && taken != null && (
        <>
          <div className="row small muted between">
            <span>{o.schedule_note}</span>
            <span className="num">
              {taken}/{o.seats} مقعد
            </span>
          </div>
          <div className="seats">
            <i style={{ width: `${Math.min(100, (taken / o.seats) * 100)}%` }} />
          </div>
        </>
      )}
    </Link>
  );
}
