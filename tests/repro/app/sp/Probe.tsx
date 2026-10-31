"use client";
import { useSearchParams } from "next/navigation";
export function Probe() { return <span>{useSearchParams().get("ok") ?? ""}</span>; }
