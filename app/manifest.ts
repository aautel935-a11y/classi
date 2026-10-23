import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Classi",
    short_name: "Classi",
    description: "معلمون خصوصيون، مجموعات تقوية، دورات معاهد وتعليم أونلاين",
    start_url: "/",
    display: "standalone",
    dir: "rtl",
    lang: "ar",
    background_color: "#FBF8F2",
    theme_color: "#1E2F6E",
    icons: [{ src: "/icon.svg", sizes: "any", type: "image/svg+xml" }],
  };
}
