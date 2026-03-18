import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

type PluginConfig = {
  pythonPath?: string;
  scriptPath?: string;
  defaultPort?: string;
};

export default function register(api: any) {
  const cfg: PluginConfig =
    api.config?.plugins?.entries?.["divoom-plugin"]?.config || api.config || {};
  const pythonPath = cfg.pythonPath || "/Users/kirniy/dev/divoom/.venv/bin/python";
  const scriptPath = cfg.scriptPath || "/Users/kirniy/dev/divoom/tools/divoom_mac.py";
  const defaultPort = cfg.defaultPort;

  async function run(args: string[]) {
    const finalArgs = [scriptPath, ...args];
    if (defaultPort && !args.includes("--port")) {
      finalArgs.push("--port", defaultPort);
    }
    try {
      const result = await execFileAsync(pythonPath, finalArgs, { maxBuffer: 8 * 1024 * 1024 });
      return result.stdout.trim() || result.stderr.trim();
    } catch (error: any) {
      const stdout = typeof error?.stdout === "string" ? error.stdout.trim() : "";
      const stderr = typeof error?.stderr === "string" ? error.stderr.trim() : "";
      return stdout || stderr || String(error);
    }
  }

  api.registerTool({
    name: "divoom_status_push",
    description: "Render live CodexBar usage to a 16x16 animation and push it to the paired Divoom",
    parameters: {
      type: "object",
      properties: {
        provider: { type: "string", enum: ["codex", "claude"] },
        port: { type: "string" }
      },
      required: ["provider"]
    },
    async execute(_id: string, params: any) {
      const args = ["send-status", "--provider", params.provider, "--terminate"];
      if (params.port) args.push("--port", params.port);
      const output = await run(args);
      return { content: [{ type: "text", text: output }] };
    }
  });

  api.registerTool({
    name: "divoom_art_push",
    description: "Render a seeded generative 16x16 animation and push it to the paired Divoom",
    parameters: {
      type: "object",
      properties: {
        style: { type: "string", enum: ["orbit", "plasma", "ripple"], default: "orbit" },
        seed: { type: "number", default: 17 },
        port: { type: "string" }
      }
    },
    async execute(_id: string, params: any) {
      const args = ["send-art", "--style", params.style ?? "orbit", "--seed", String(params.seed ?? 17), "--terminate"];
      if (params.port) args.push("--port", params.port);
      const output = await run(args);
      return { content: [{ type: "text", text: output }] };
    }
  });

  api.registerTool({
    name: "divoom_media_push",
    description: "Upload an image or GIF file to the paired Divoom",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string" },
        port: { type: "string" }
      },
      required: ["path"]
    },
    async execute(_id: string, params: any) {
      const args = ["send-file", params.path, "--terminate"];
      if (params.port) args.push("--port", params.port);
      const output = await run(args);
      return { content: [{ type: "text", text: output }] };
    }
  });

  api.registerTool({
    name: "divoom_divoom16_push",
    description: "Upload a prebuilt Divoom 16x16 animation file to the paired Divoom",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string" },
        port: { type: "string" }
      },
      required: ["path"]
    },
    async execute(_id: string, params: any) {
      const args = ["send-divoom16", params.path, "--terminate"];
      if (params.port) args.push("--port", params.port);
      const output = await run(args);
      return { content: [{ type: "text", text: output }] };
    }
  });

  api.registerTool({
    name: "divoom_text_push",
    description: "Render simple text and push it to the paired Divoom",
    parameters: {
      type: "object",
      properties: {
        text: { type: "string" },
        port: { type: "string" }
      },
      required: ["text"]
    },
    async execute(_id: string, params: any) {
      const args = ["send-text", params.text, "--terminate"];
      if (params.port) args.push("--port", params.port);
      const output = await run(args);
      return { content: [{ type: "text", text: output }] };
    }
  });

  api.registerTool({
    name: "divoom_volume_get",
    description: "Read the current Divoom volume from the paired device",
    parameters: {
      type: "object",
      properties: {
        port: { type: "string" }
      }
    },
    async execute(_id: string, params: any) {
      const args = ["volume-get"];
      if (params.port) args.push("--port", params.port);
      const output = await run(args);
      return { content: [{ type: "text", text: output }] };
    }
  });

  api.registerTool({
    name: "divoom_sound_play",
    description: "Play an attention or completion sound through DitooPro-Audio",
    parameters: {
      type: "object",
      properties: {
        profile: { type: "string", enum: ["attention", "complete"], default: "attention" }
      }
    },
    async execute(_id: string, params: any) {
      const output = await run(["play-sound", "--profile", params.profile ?? "attention"]);
      return { content: [{ type: "text", text: output }] };
    }
  });
}
