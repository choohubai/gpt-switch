import fs from "node:fs";
import path from "node:path";
import { atomicWrite } from "./model-config.mjs";

export const DEFAULT_APPEARANCE_THEME = "light";

/// 面板和注入器共用这一份主题目录，避免 macOS、Windows 与 ChatGPT 样式各自维护名称。
export const APPEARANCE_THEMES = [
  {
    id: "light",
    name: "浅色",
    previewFile: "light-preview.jpg",
    cardBackground: "#f0f0f0",
    runtime: {
      background: "#f7f8f9",
      sidebar: "rgba(239, 241, 244, 0.88)",
      surface: "rgba(255, 255, 255, 0.72)",
      composer: "rgba(255, 255, 255, 0.94)",
      text: "#1d2023",
      muted: "#697078",
      border: "rgba(29, 32, 35, 0.12)",
      accent: "#4b7f58",
    },
  },
  {
    id: "dark",
    name: "深色",
    previewFile: "dark-preview.jpg",
    cardBackground: "#303030",
    colorScheme: "dark",
    runtime: {
      background: "#17191c",
      sidebar: "rgba(18, 20, 23, 0.9)",
      surface: "rgba(31, 34, 38, 0.74)",
      composer: "rgba(41, 44, 48, 0.96)",
      text: "#f3f4f5",
      muted: "#b7bbc2",
      border: "rgba(255, 255, 255, 0.14)",
      accent: "#8dc49a",
    },
  },
  {
    id: "wind",
    name: "有风",
    previewFile: "wind-preview.jpg",
    backgroundFile: "wind-bg.png",
    runtime: {
      background: "#edf6e8",
      sidebar: "rgba(239, 246, 234, 0.88)",
      surface: "rgba(255, 255, 255, 0.58)",
      composer: "rgba(255, 255, 255, 0.9)",
      text: "#203026",
      muted: "#617368",
      border: "rgba(54, 88, 64, 0.16)",
      accent: "#4f805b",
      imagePosition: "center bottom",
      imageSize: "cover",
    },
  },
  {
    id: "qq",
    name: "经典 QQ",
    previewFile: "qq-preview.png",
    backgroundFile: "qq-bg.png",
    runtime: {
      background: "#f5f9ff",
      sidebar: "rgba(237, 245, 255, 0.94)",
      surface: "rgba(255, 255, 255, 0.7)",
      composer: "rgba(255, 255, 255, 0.96)",
      text: "#17243a",
      muted: "#61718a",
      border: "rgba(35, 75, 129, 0.14)",
      accent: "#2e73cf",
      imagePosition: "right bottom",
      imageSize: "min(72vw, 720px) auto",
    },
  },
  {
    id: "peace",
    name: "和平精英激战金秋",
    previewFile: "peace-preview.jpg",
    backgroundFile: "peace-bg.png",
    runtime: {
      background: "#d8ebf7",
      sidebar: "rgba(244, 249, 253, 0.84)",
      surface: "rgba(255, 255, 255, 0.54)",
      composer: "rgba(255, 255, 255, 0.91)",
      text: "#182838",
      muted: "#5f7080",
      border: "rgba(34, 72, 101, 0.16)",
      accent: "#3b7191",
      imagePosition: "center center",
      imageSize: "cover",
    },
  },
  {
    id: "journey",
    name: "同行",
    previewFile: "journey-preview.jpg",
    backgroundFile: "journey-bg.png",
    runtime: {
      background: "#dff6ff",
      sidebar: "rgba(237, 250, 255, 0.88)",
      surface: "rgba(255, 255, 255, 0.55)",
      composer: "rgba(255, 255, 255, 0.92)",
      text: "#173544",
      muted: "#607881",
      border: "rgba(39, 105, 130, 0.15)",
      accent: "#3a819b",
      imagePosition: "center center",
      imageSize: "cover",
    },
  },
  {
    id: "ripple",
    name: "涟漪",
    previewFile: "ripple-preview.jpg",
    backgroundFile: "ripple-bg.png",
    runtime: {
      background: "#e6f4fc",
      sidebar: "rgba(241, 249, 254, 0.9)",
      surface: "rgba(255, 255, 255, 0.62)",
      composer: "rgba(255, 255, 255, 0.94)",
      text: "#20343f",
      muted: "#667d88",
      border: "rgba(58, 107, 132, 0.14)",
      accent: "#4b879e",
      imagePosition: "center bottom",
      imageSize: "cover",
    },
  },
  {
    id: "buddy",
    name: "伙伴",
    previewFile: "buddy-preview.jpg",
    backgroundFile: "buddy-bg.png",
    runtime: {
      background: "#f6efff",
      sidebar: "rgba(248, 243, 255, 0.9)",
      surface: "rgba(255, 255, 255, 0.66)",
      composer: "rgba(255, 255, 255, 0.95)",
      text: "#2c2533",
      muted: "#746b7e",
      border: "rgba(91, 72, 111, 0.14)",
      accent: "#8059a6",
      imagePosition: "center bottom",
      imageSize: "cover",
    },
  },
];

const themeById = new Map(APPEARANCE_THEMES.map((theme) => [theme.id, theme]));
const normalizeNativeAppearanceMode = (value) => (value === "dark" ? "dark" : "light");

/// 外部文件或旧配置里的主题只在清单内时才放行，未知值回到原生浅色。
export const normalizeAppearanceTheme = (value) => (
  typeof value === "string" && themeById.has(value) ? value : DEFAULT_APPEARANCE_THEME
);

/// 原生客户端只保留深、浅两档；插画主题统一建立浅色底，再叠加自己的色板。
export const appearanceNativeMode = (value) => (
  themeById.get(normalizeAppearanceTheme(
    typeof value === "object" ? value?.theme : value,
  ))?.colorScheme === "dark" ? "dark" : "light"
);

/// 读取主题选择及“跟随原生”状态；配置损坏或尚未创建时不阻断面板启动。
export const readAppearanceState = (configPath) => {
  try {
    const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
    return {
      theme: normalizeAppearanceTheme(parsed?.theme),
      followNative: parsed?.followNative === true,
      nativeMode: normalizeNativeAppearanceMode(parsed?.nativeMode),
    };
  } catch {
    return {
      theme: DEFAULT_APPEARANCE_THEME,
      followNative: false,
      nativeMode: "light",
    };
  }
};

/// 保存唯一主题 ID；主动选择 GPT Switch 主题时重新启用外观覆盖。
export const writeAppearanceTheme = (configPath, value) => {
  const theme = normalizeAppearanceTheme(value);
  atomicWrite(configPath, `${JSON.stringify({ theme }, null, 2)}\n`);
  return theme;
};

/// 用户改选 ChatGPT 原生模式后暂停 GPT Switch 覆盖，并把面板选中项同步到对应原生主题。
export const writeNativeAppearanceOverride = (configPath, mode) => {
  const nativeMode = normalizeNativeAppearanceMode(mode);
  const next = {
    theme: nativeMode,
    followNative: true,
    nativeMode,
  };
  atomicWrite(configPath, `${JSON.stringify(next, null, 2)}\n`);
  return next;
};

export const readAppearanceTheme = (configPath) => readAppearanceState(configPath).theme;

const previewPath = (resourceDirectory, file) => path.join(resourceDirectory, file);

/// 把面板需要的主题元数据一次返回；previewPath 指向安装包内的本地图片。
export const appearancePanelState = (configPath, resourceDirectory) => ({
  ...readAppearanceState(configPath),
  themes: APPEARANCE_THEMES.map((theme) => ({
    id: theme.id,
    name: theme.name,
    previewPath: previewPath(resourceDirectory, theme.previewFile),
    coverPath: theme.backgroundFile ? previewPath(resourceDirectory, theme.backgroundFile) : "",
    cardBackground: theme.cardBackground || "",
    colorScheme: theme.colorScheme || "light",
  })),
});

const fileAsDataUrl = (resourceDirectory, file) => {
  const target = previewPath(resourceDirectory, file);
  if (!fs.existsSync(target)) return "";
  const mime = path.extname(target).toLowerCase() === ".jpg" ? "image/jpeg" : "image/png";
  return `data:${mime};base64,${fs.readFileSync(target).toString("base64")}`;
};

/// 生成注入脚本所需的最小运行态：颜色令牌与可选背景 data URL。
export const appearanceRuntimeTheme = (value, resourceDirectory) => {
  const state = typeof value === "object"
    ? value
    : { theme: value, followNative: false };
  if (state?.followNative === true) return null;
  const theme = themeById.get(normalizeAppearanceTheme(state?.theme));
  if (!theme) return null;
  return {
    id: theme.id,
    colorScheme: theme.colorScheme || "light",
    ...theme.runtime,
    imageUrl: theme.backgroundFile
      ? fileAsDataUrl(resourceDirectory, theme.backgroundFile)
      : "",
  };
};
