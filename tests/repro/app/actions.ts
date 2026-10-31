"use server";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
export async function same() { revalidatePath("/"); redirect("/?ok=1"); }
export async function hash() { revalidatePath("/"); redirect("/?ok=2#part"); }
export async function other() { redirect("/r?ok=3"); }
export async function kf() { revalidatePath("/kf"); redirect("/kf?ok=1"); }
export async function sp() { revalidatePath("/sp"); redirect("/sp?ok=1"); }
