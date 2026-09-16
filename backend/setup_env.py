"""交互式写入 backend/.env 的小工具。

在 backend 目录下执行：
    venv\\Scripts\\python.exe setup_env.py

按提示粘贴两个密钥即可，脚本会自动写好 .env 文件，不需要手动编辑。
"""

from pathlib import Path

ENV_PATH = Path(__file__).with_name(".env")

TEMPLATE = """# 本地开发环境变量（已被 .gitignore 忽略，不会提交）
DEEPSEEK_API_KEY={deepseek}
AMAP_KEY={amap}
ALLOW_ORIGINS=*
"""

DEEPSEEK_HINT = (
    "DeepSeek 密钥以 sk- 开头。\n"
    "  获取地址：https://platform.deepseek.com/api_keys"
)

AMAP_HINT = (
    "高德密钥是 32 位字符。注意必须选「Web 服务」类型，\n"
    "  选成「Web 端(JS API)」的话后端调用会报 INVALID_USER_KEY。\n"
    "  创建地址：https://console.amap.com/dev/key/app"
)


def ask(name: str, hint: str) -> str:
    while True:
        print(f"\n{hint}")
        value = input(f"请粘贴 {name}，然后按回车：").strip().strip('"').strip("'")
        if value:
            return value
        print("  ⚠️ 输入为空，请重新粘贴。")


def main() -> None:
    print("=" * 58)
    print("家教出行助手 · 本地环境变量配置")
    print("=" * 58)
    print("两个密钥只写入本地 .env 文件，不会被打印出来，也不会提交到 git。")

    deepseek = ask("DEEPSEEK_API_KEY", DEEPSEEK_HINT)
    amap = ask("AMAP_KEY", AMAP_HINT)

    ENV_PATH.write_text(
        TEMPLATE.format(deepseek=deepseek, amap=amap),
        encoding="utf-8",
    )

    print(f"\n✅ 已写入 {ENV_PATH}")
    print(f"   DEEPSEEK_API_KEY 长度 {len(deepseek)}，AMAP_KEY 长度 {len(amap)}")
    print("\n接下来在 backend 目录执行下面这条命令启动后端：")
    print("   venv\\Scripts\\python.exe -m uvicorn main:app --reload --port 8000")


if __name__ == "__main__":
    main()
