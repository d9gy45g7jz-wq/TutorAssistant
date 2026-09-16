"use client";

import { useState } from "react";

// =====================================
// 配置
// =====================================

// 优先读环境变量；未配置时本地开发指向本机后端，线上回退到已部署地址
const FALLBACK_API =
  process.env.NODE_ENV === "production"
    ? "https://tutorassistant-api.onrender.com"
    : "http://127.0.0.1:8000";

const API = (
  process.env.NEXT_PUBLIC_API_BASE?.trim() || FALLBACK_API
).replace(/\/$/, "");

// 单次请求超时时间。Render 免费实例冷启动可能需要 30s 以上，所以放宽到 60s
const REQUEST_TIMEOUT_MS = 60_000;

// =====================================
// 类型
// =====================================

type ParsedInfo = Record<string, string>;

type Point = {
  lng: number;
  lat: number;
  name: string;
  city: string;
};

type RouteMode = "driving" | "bicycling" | "transit" | "walking";

type RouteInfo = {
  available: boolean;
  distance_km?: number;
  duration_minutes?: number;
};

type RoutesResult = {
  success: boolean;
  fastest: RouteMode | null;
  routes: Record<string, RouteInfo>;
};

// =====================================
// 常量
// =====================================

const FIELD_LABELS: Record<string, string> = {
  科目: "科目",
  学生: "学生",
  地点: "地点",
  时间: "上课时间",
  课时: "课时",
  价格: "价格",
  经验: "经验要求",
};

const ROUTE_NAMES: Record<RouteMode, string> = {
  driving: "🚗 驾车",
  bicycling: "🛵 电动车",
  transit: "🚇 公交地铁",
  walking: "🚶 步行",
};

// =====================================
// 请求工具
// =====================================

function detailOf(data: unknown): string | null {
  if (data === null || typeof data !== "object" || !("detail" in data)) {
    return null;
  }
  const detail = (data as { detail?: unknown }).detail;
  if (typeof detail === "string") {
    return detail;
  }
  return "请求参数有误";
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return "发生未知错误，请稍后重试";
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const res = await fetch(`${API}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    const data: unknown = await res.json().catch(() => null);

    if (data === null || (data as { success?: boolean }).success !== true) {
      throw new Error(
        detailOf(data) ?? `请求失败（HTTP ${res.status}）`
      );
    }

    return data as T;
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new Error("请求超时，服务可能正在冷启动，请稍后重试");
    }
    if (error instanceof TypeError) {
      throw new Error("无法连接后端服务，请确认后端已启动且地址配置正确");
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

// =====================================
// 地址输入组件
// =====================================

type AddressFieldProps = {
  id: string;
  label: string;
  placeholder: string;
  buttonText: string;
  value: string;
  loading: boolean;
  location: Point | null;
  onChange: (value: string) => void;
  onSubmit: () => void;
};

function AddressField({
  id,
  label,
  placeholder,
  buttonText,
  value,
  loading,
  location,
  onChange,
  onSubmit,
}: AddressFieldProps) {
  return (
    <div className="mt-5">
      <label htmlFor={id} className="block font-medium text-slate-900">
        {label}
      </label>

      <input
        id={id}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        className="w-full border border-slate-300 rounded-xl p-3 mt-2 text-slate-900 placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-green-500"
      />

      <button
        type="button"
        onClick={onSubmit}
        disabled={loading}
        className="bg-green-600 text-white rounded-xl px-5 py-3 mt-3 transition hover:bg-green-700 disabled:bg-slate-300 disabled:cursor-not-allowed"
      >
        {loading ? "⏳ 正在解析..." : buttonText}
      </button>

      {location && (
        <p className="text-green-600 mt-3">✅ 已定位：{location.name}</p>
      )}
    </div>
  );
}

// =====================================
// 页面
// =====================================

export default function Home() {
  // 输入
  const [chat, setChat] = useState("");
  const [myAddress, setMyAddress] = useState("");
  const [tutorAddress, setTutorAddress] = useState("");

  // 数据
  const [aiData, setAiData] = useState<ParsedInfo | null>(null);
  const [myLocation, setMyLocation] = useState<Point | null>(null);
  const [tutorLocation, setTutorLocation] = useState<Point | null>(null);
  const [routes, setRoutes] = useState<RoutesResult | null>(null);

  // 状态
  const [aiLoading, setAiLoading] = useState(false);
  const [myLoading, setMyLoading] = useState(false);
  const [tutorLoading, setTutorLoading] = useState(false);
  const [routeLoading, setRouteLoading] = useState(false);
  const [msg, setMsg] = useState("");

  // AI 解析
  async function parseAI() {
    if (!chat.trim()) {
      setMsg("请输入家教聊天记录");
      return;
    }

    setAiLoading(true);
    setMsg("");

    try {
      const data = await postJSON<{ result: ParsedInfo }>("/api/ai/parse", {
        text: chat,
      });

      setAiData(data.result);

      const place = data.result["地点"];
      if (place) {
        setTutorAddress(place);
      }
    } catch (error) {
      setMsg(errorMessage(error));
    } finally {
      setAiLoading(false);
    }
  }

  // 地址解析
  async function geocodeAddress(address: string, type: "mine" | "tutor") {
    if (!address.trim()) {
      setMsg("请输入地址");
      return;
    }

    if (type === "mine") {
      setMyLoading(true);
    } else {
      setTutorLoading(true);
    }
    setMsg("");

    try {
      const data = await postJSON<{
        lng: number;
        lat: number;
        city: string;
        formatted_address: string;
      }>("/api/geocode", { address });

      const point: Point = {
        lng: data.lng,
        lat: data.lat,
        name: data.formatted_address,
        city: data.city,
      };

      if (type === "mine") {
        setMyLocation(point);
      } else {
        setTutorLocation(point);
      }

      // 地址变了，之前的路线结果就作废了
      setRoutes(null);
    } catch (error) {
      setMsg(errorMessage(error));
    } finally {
      if (type === "mine") {
        setMyLoading(false);
      } else {
        setTutorLoading(false);
      }
    }
  }

  // 路线计算
  async function calculateRoute() {
    if (!myLocation || !tutorLocation) {
      setMsg("请先解析两个地址");
      return;
    }

    setRouteLoading(true);
    setMsg("");

    try {
      const data = await postJSON<RoutesResult>("/api/routes", {
        origin_lng: myLocation.lng,
        origin_lat: myLocation.lat,
        destination_lng: tutorLocation.lng,
        destination_lat: tutorLocation.lat,
        // 公交方案需要城市名，从地理编码结果里带过去
        city: tutorLocation.city || myLocation.city || "",
      });

      setRoutes(data);
    } catch (error) {
      setMsg(errorMessage(error));
    } finally {
      setRouteLoading(false);
    }
  }

  const availableRoutes = routes
    ? (Object.entries(routes.routes) as [RouteMode, RouteInfo][]).filter(
        ([, info]) => info.available
      )
    : [];

  return (
    <main className="min-h-screen bg-slate-100 text-slate-900 p-6">
      <div className="max-w-5xl mx-auto">
        <h1 className="text-4xl font-bold mb-8">🏫 家教出行助手</h1>

        {msg && (
          <div className="bg-red-100 text-red-700 rounded-xl p-4 mb-5">
            {msg}
          </div>
        )}

        {/* AI 区域 */}
        <section className="bg-white rounded-2xl shadow p-6 mb-6">
          <h2 className="text-xl font-bold">🤖 AI 解析家教信息</h2>

          <label htmlFor="chat" className="sr-only">
            家教聊天记录
          </label>
          <textarea
            id="chat"
            className="w-full h-36 border border-slate-300 rounded-xl p-4 mt-4 text-slate-900 placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
            value={chat}
            onChange={(event) => setChat(event.target.value)}
            placeholder={
              "粘贴家教聊天记录，例如：\n英语家教，浦东新区XX小区，周六下午2点，两小时"
            }
          />

          <button
            type="button"
            onClick={parseAI}
            disabled={aiLoading}
            className="bg-blue-600 text-white px-6 py-3 rounded-xl mt-4 transition hover:bg-blue-700 disabled:bg-slate-300 disabled:cursor-not-allowed"
          >
            {aiLoading ? "⏳ AI 解析中..." : "🤖 开始解析"}
          </button>

          {aiData && (
            <div className="bg-blue-50 rounded-xl mt-5 p-5">
              {Object.entries(aiData).map(([key, value]) => (
                <p key={key} className="mb-2">
                  <b>{FIELD_LABELS[key] ?? key}</b>：{value || "未提及"}
                </p>
              ))}
            </div>
          )}
        </section>

        {/* 地址区域 */}
        <section className="bg-white rounded-2xl shadow p-6 mb-6">
          <h2 className="text-xl font-bold">📍 地址设置</h2>

          <AddressField
            id="my-address"
            label="我的当前位置"
            placeholder="输入你的地址，例如：上海市徐汇区漕溪北路100号"
            buttonText="📍 解析我的位置"
            value={myAddress}
            loading={myLoading}
            location={myLocation}
            onChange={setMyAddress}
            onSubmit={() => geocodeAddress(myAddress, "mine")}
          />

          <AddressField
            id="tutor-address"
            label="家教地点"
            placeholder="输入家教地址"
            buttonText="📍 解析家教地点"
            value={tutorAddress}
            loading={tutorLoading}
            location={tutorLocation}
            onChange={setTutorAddress}
            onSubmit={() => geocodeAddress(tutorAddress, "tutor")}
          />
        </section>

        {/* 出行区域 */}
        <section className="bg-white rounded-2xl shadow p-6">
          <h2 className="text-xl font-bold">🚦 出行方案</h2>

          <button
            type="button"
            onClick={calculateRoute}
            disabled={routeLoading}
            className="bg-purple-600 text-white rounded-xl px-6 py-3 mt-4 transition hover:bg-purple-700 disabled:bg-slate-300 disabled:cursor-not-allowed"
          >
            {routeLoading ? "⏳ 计算中..." : "🚀 计算最佳路线"}
          </button>

          {routes && (
            <div className="mt-6">
              <h3 className="text-xl font-bold mb-5">
                {routes.fastest
                  ? `⭐ 最快：${ROUTE_NAMES[routes.fastest]}`
                  : "⭐ 暂无可用的出行方案"}
              </h3>

              {availableRoutes.length === 0 && (
                <p className="text-slate-600">
                  没有查到任何可用路线，请确认两个地址解析正确后重试。
                </p>
              )}

              {availableRoutes.map(([key, info]) => (
                <div key={key} className="border border-slate-200 rounded-xl p-5 mb-4">
                  <h4 className="font-bold text-lg">{ROUTE_NAMES[key]}</h4>
                  <p>距离：{info.distance_km} km</p>
                  <p>时间：{info.duration_minutes} 分钟</p>
                </div>
              ))}

              {routes.routes.transit?.available === false && (
                <p className="text-sm text-slate-500">
                  公交方案不可用：地址中带上城市名后重新解析，即可查询公交地铁方案。
                </p>
              )}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
