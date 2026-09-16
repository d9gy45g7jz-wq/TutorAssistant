import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // 导出为纯静态文件（生成 out 目录），可以托管到任意静态托管平台，
  // 也可以由服务器上的 nginx 直接提供，不需要在生产环境运行 Node 服务。
  output: "export",
};

export default nextConfig;
