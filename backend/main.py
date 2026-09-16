"""家教出行助手后端服务。

提供三类能力：

1. ``POST /api/ai/parse``  调用 DeepSeek，从家教聊天记录中提取结构化信息
2. ``POST /api/geocode``   调用高德地理编码，把文字地址转成经纬度
3. ``POST /api/routes``    调用高德路径规划，返回驾车 / 电动车 / 步行 / 公交四种方案

环境变量配置见 ``.env.example``。
"""

import asyncio
import json
import logging
import os
import re
import time
from collections import defaultdict, deque

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

load_dotenv()

logger = logging.getLogger("tutor_assistant")
logging.basicConfig(level=logging.INFO)

# =====================================
# 配置
# =====================================

AMAP_KEY = os.getenv("AMAP_KEY", "")
DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY", "")

DEEPSEEK_ENDPOINT = os.getenv(
    "DEEPSEEK_BASE_URL",
    "https://api.deepseek.com/chat/completions",
)
DEEPSEEK_MODEL = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")

# 允许跨域的来源，多个用英文逗号分隔。默认 "*" 方便本地开发，上线建议收紧。
ALLOW_ORIGINS = [
    origin.strip()
    for origin in os.getenv("ALLOW_ORIGINS", "*").split(",")
    if origin.strip()
]

# 单个 IP 在 RATE_WINDOW 秒内最多请求 RATE_LIMIT 次，设为 0 关闭限流。
RATE_LIMIT = int(os.getenv("RATE_LIMIT", "60"))
RATE_WINDOW = int(os.getenv("RATE_WINDOW", "60"))

AMAP_GEOCODE_URL = "https://restapi.amap.com/v3/geocode/geo"

ROUTE_ENDPOINTS = {
    "driving": "https://restapi.amap.com/v3/direction/driving",
    "walking": "https://restapi.amap.com/v3/direction/walking",
    "transit": "https://restapi.amap.com/v3/direction/transit/integrated",
}

# 电动车估算参数：城市平均时速 18km/h，再乘以红绿灯等待系数
EBIKE_SPEED_KMH = 18.0
EBIKE_DELAY_FACTOR = 1.2

# =====================================
# 应用
# =====================================

app = FastAPI(title="Tutor Assistant")

_rate_buckets: dict[str, deque] = defaultdict(deque)


@app.middleware("http")
async def rate_limit(request: Request, call_next):
    """极简的进程内限流，避免接口被随意刷取消耗上游额度。"""
    if RATE_LIMIT <= 0:
        return await call_next(request)

    client_ip = request.client.host if request.client else "unknown"
    now = time.monotonic()
    hits = _rate_buckets[client_ip]

    while hits and now - hits[0] > RATE_WINDOW:
        hits.popleft()

    if len(hits) >= RATE_LIMIT:
        return JSONResponse(
            status_code=429,
            content={"detail": "请求过于频繁，请稍后再试"},
        )

    hits.append(now)
    return await call_next(request)


# 注意：CORS 中间件最后注册，因此位于最外层，
# 这样限流返回的 429 响应也会带上跨域头，前端才能读到错误信息。
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOW_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

_http_client: httpx.AsyncClient | None = None


def get_http() -> httpx.AsyncClient:
    """复用同一个连接池，避免每次请求都重新建连。"""
    global _http_client
    if _http_client is None or _http_client.is_closed:
        _http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(60.0, connect=10.0),
        )
    return _http_client


# =====================================
# 数据模型
# =====================================


class AIRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=8000)


class AddressRequest(BaseModel):
    address: str = Field(..., min_length=1, max_length=200)


class RouteRequest(BaseModel):
    origin_lng: float
    origin_lat: float
    destination_lng: float
    destination_lat: float
    # 公交路径规划必须提供城市名，由前端从 /api/geocode 的结果带过来
    city: str = ""


# =====================================
# 配置校验
# =====================================


def check_ai() -> None:
    if not DEEPSEEK_API_KEY:
        raise HTTPException(503, "服务端尚未配置 DEEPSEEK_API_KEY")


def check_amap() -> None:
    if not AMAP_KEY:
        raise HTTPException(503, "服务端尚未配置 AMAP_KEY")


# =====================================
# 首页
# =====================================


@app.get("/")
async def root():
    return {"success": True, "message": "Tutor Assistant Running"}


@app.get("/api/health")
async def health():
    """健康检查：浏览器直接打开 /api/health 就能确认服务与密钥状态。"""
    return {
        "success": True,
        "deepseek_configured": bool(DEEPSEEK_API_KEY),
        "amap_configured": bool(AMAP_KEY),
    }


# =====================================
# AI 解析
# =====================================

AI_PROMPT = """
你是家教信息解析助手。
请从用户提供的聊天记录中提取家教需求信息。

必须返回 JSON，且只返回 JSON，不要输出任何解释文字。

格式：
{
"科目": "",
"学生": "",
"地点": "",
"时间": "",
"课时": "",
"价格": "",
"经验": ""
}

规则：
1. 所有字段名称必须为中文。
2. 科目必须翻译成中文，例如 English 返回 英语，Math 返回 数学。
3. 地址保持中文原文。
4. "课时"填写每次上课时长（如"两小时"），"时间"填写上课的具体时段（如"周六下午2点"）。
5. 无法从原文中确定的字段，返回空字符串，不要编造。
""".strip()

JSON_FENCE = re.compile(r"```(?:json)?", re.IGNORECASE)


def parse_json(text: str) -> dict:
    """从模型输出中提取 JSON 对象。

    模型有时会把 JSON 包在 ```json 代码块里，或在前后附带说明文字，
    这里统一剥离后再解析。
    """
    cleaned = JSON_FENCE.sub("", text).replace("```", "").strip()

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start != -1 and end > start:
        cleaned = cleaned[start : end + 1]

    result = json.loads(cleaned)
    if not isinstance(result, dict):
        raise ValueError("模型返回的内容不是 JSON 对象")
    return result


@app.post("/api/ai/parse")
async def ai_parse(payload: AIRequest):
    check_ai()

    body = {
        "model": DEEPSEEK_MODEL,
        "messages": [
            {"role": "system", "content": AI_PROMPT},
            {"role": "user", "content": payload.text},
        ],
        "temperature": 0.1,
        # 强制返回合法 JSON，从源头避免解析失败
        "response_format": {"type": "json_object"},
    }

    headers = {
        "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
        "Content-Type": "application/json",
    }

    try:
        response = await get_http().post(
            DEEPSEEK_ENDPOINT,
            headers=headers,
            json=body,
        )
    except httpx.HTTPError as exc:
        logger.warning("调用 DeepSeek 失败: %s", exc)
        raise HTTPException(502, "AI 服务暂时不可用，请稍后重试")

    if response.status_code != 200:
        # 上游返回的原文只记录在服务端日志，不返回给浏览器
        logger.warning(
            "DeepSeek 返回 %s: %s",
            response.status_code,
            response.text[:500],
        )
        raise HTTPException(502, f"AI 服务返回异常（{response.status_code}）")

    try:
        content = response.json()["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        logger.warning("DeepSeek 响应结构异常: %s", exc)
        raise HTTPException(502, "AI 返回内容格式异常，请重试")

    try:
        result = parse_json(content)
    except (ValueError, TypeError) as exc:
        logger.warning("AI 返回内容无法解析为 JSON: %s", exc)
        raise HTTPException(502, "AI 未能返回结构化信息，请重试")

    return {"success": True, "result": result}


# =====================================
# 地址解析
# =====================================


def first_text(value) -> str:
    """高德部分字段可能返回字符串或字符串数组，这里统一成字符串。"""
    if isinstance(value, list):
        return str(value[0]) if value else ""
    if value is None:
        return ""
    return str(value)


@app.post("/api/geocode")
async def geocode(payload: AddressRequest):
    check_amap()

    params = {
        "key": AMAP_KEY,
        "address": payload.address,
        "output": "json",
    }

    try:
        res = await get_http().get(AMAP_GEOCODE_URL, params=params, timeout=15)
        data = res.json()
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("高德地理编码请求失败: %s", exc)
        raise HTTPException(502, "地址解析服务暂时不可用，请稍后重试")

    if data.get("status") != "1":
        message = first_text(data.get("info")) or "地址解析失败"
        raise HTTPException(400, message)

    geocodes = data.get("geocodes") or []
    if not geocodes:
        raise HTTPException(404, "没有找到该地址，请补充所在城市或更详细的描述")

    first = geocodes[0]
    location = first_text(first.get("location"))
    if "," not in location:
        raise HTTPException(502, "地址解析结果异常，请稍后重试")

    lng, lat = location.split(",", 1)

    return {
        "success": True,
        "lng": float(lng),
        "lat": float(lat),
        "city": first_text(first.get("city")),
        "formatted_address": first_text(first.get("formatted_address"))
        or payload.address,
    }


# =====================================
# 高德路线请求
# =====================================


async def amap_route(
    mode: str,
    origin: str,
    destination: str,
    city: str = "",
):
    """请求高德路径规划，失败时返回 None，由调用方降级处理。"""
    url = ROUTE_ENDPOINTS.get(mode)
    if url is None:
        return None

    params = {
        "key": AMAP_KEY,
        "origin": origin,
        "destination": destination,
        "output": "json",
    }

    if mode == "transit":
        if not city:
            # 公交路径规划必须指定城市，缺失时直接跳过，
            # 而不是硬编码成某个城市返回错误结果
            logger.info("缺少城市信息，跳过公交方案")
            return None
        params["city"] = city

    try:
        res = await get_http().get(url, params=params, timeout=20)
        data = res.json()
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("高德 %s 路线请求失败: %s", mode, exc)
        return None

    if data.get("status") != "1":
        logger.warning(
            "高德 %s 路线返回异常: %s",
            mode,
            data.get("info"),
        )
        return None

    return data


# =====================================
# 路线解析
# =====================================


def parse_route(mode: str, data) -> dict:
    """把高德返回的路线数据整理成前端需要的距离和耗时。"""
    try:
        route = data["route"]
        item = route["transits"][0] if mode == "transit" else route["paths"][0]

        distance = float(item.get("distance") or 0)
        duration = float(item.get("duration") or 0)

        return {
            "available": True,
            "distance_km": round(distance / 1000, 2),
            "duration_minutes": max(1, round(duration / 60)),
        }
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        logger.info("解析 %s 路线失败: %s", mode, exc)
        return {"available": False}


UNAVAILABLE = {"available": False}


def route_or_unavailable(mode: str, result) -> dict:
    """把 amap_route 的返回值（可能是 None 或异常）转成统一结构。"""
    if isinstance(result, BaseException) or not result:
        return dict(UNAVAILABLE)
    return parse_route(mode, result)


# =====================================
# 电动车计算
# =====================================


def calculate_bike_time(distance_km: float) -> int:
    minutes = distance_km / EBIKE_SPEED_KMH * 60 * EBIKE_DELAY_FACTOR
    return max(1, round(minutes))


def bicycle_from_driving(driving: dict) -> dict:
    """高德没有电动车接口，用驾车道路距离配合经验时速估算。"""
    if not driving.get("available"):
        return dict(UNAVAILABLE)

    return {
        "available": True,
        "distance_km": driving["distance_km"],
        "duration_minutes": calculate_bike_time(driving["distance_km"]),
    }


# =====================================
# 总路线接口
# =====================================

# 耗时相同时的推荐优先级
MODE_PRIORITY = ["bicycling", "driving", "transit", "walking"]


@app.post("/api/routes")
async def routes(payload: RouteRequest):
    check_amap()

    origin = f"{payload.origin_lng},{payload.origin_lat}"
    destination = f"{payload.destination_lng},{payload.destination_lat}"

    # 三种出行方式并行请求，总耗时取决于最慢的一个，而不是三者之和
    driving_data, walking_data, transit_data = await asyncio.gather(
        amap_route("driving", origin, destination),
        amap_route("walking", origin, destination),
        amap_route("transit", origin, destination, city=payload.city),
        return_exceptions=True,
    )

    driving = route_or_unavailable("driving", driving_data)

    result = {
        "driving": driving,
        "walking": route_or_unavailable("walking", walking_data),
        "transit": route_or_unavailable("transit", transit_data),
        # 复用驾车距离，不再重复请求一次高德
        "bicycling": bicycle_from_driving(driving),
    }

    fastest = None
    best_time = float("inf")

    for mode in MODE_PRIORITY:
        item = result.get(mode) or {}
        if not item.get("available"):
            continue
        duration = item.get("duration_minutes") or float("inf")
        if duration < best_time:
            best_time = duration
            fastest = mode

    return {"success": True, "fastest": fastest, "routes": result}


# =====================================
# 启动
# =====================================

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=os.getenv("HOST", "0.0.0.0"),
        # 部署平台（如 Render）会通过 PORT 注入端口
        port=int(os.getenv("PORT", "8000")),
    )
