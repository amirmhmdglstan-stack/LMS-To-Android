# 🧠 LM Studio → Android Host

**Serve a model from LM Studio on your Windows PC and connect to it from Android with an OpenAI-compatible API URL.** Choose a downloaded model from a numbered menu, let the script clear the previous session, and copy the connection settings into **LMSMOB Chat**.

![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?logo=windows&logoColor=white)
![LM Studio CLI](https://img.shields.io/badge/requires-LM%20Studio%20CLI-6C63FF)
![Format](https://img.shields.io/badge/script-single%20BAT-2EA44F)

> [!IMPORTANT]
> This script stops the active LM Studio API server and unloads **all models currently loaded in LM Studio** before loading your selection. It does **not** delete downloaded models or model files.
>
> The server binds to `0.0.0.0` so other devices on your network can reach it. Read [Security notes](#-security-notes) before using it on a network you do not fully trust.

## ✨ Features

- **Model picker:** lists downloaded LLMs using `lms ls --llm --json` and presents a numbered menu.
- **Context length prompt:** uses `4096` tokens by default; you can enter another value supported by your selected model.
- **Clean model switch:** stops the prior LM Studio server and requests that all loaded models be unloaded before the new model is loaded.
- **Empty-state handling:** handles the “no models are currently loaded” message even when a CLI version writes it to standard error or returns a non-zero exit code. It also understands documented JSON output and checks the state again before loading.
- **Automatic GPU allocation:** does not pass the unsupported `--gpu auto` argument. Omitting `--gpu` lets LM Studio apply its default GPU-allocation behavior.
- **Consistent API model ID:** loads the chosen model with the identifier `lmsmob-chat` so the client has a predictable model name to enter.
- **LAN API:** starts the OpenAI-compatible server on port `1234` and binds it to all IPv4 interfaces.
- **Startup checks:** checks model loading, server startup, TCP availability, the `/v1/models` endpoint when possible, and the network listener when Windows exposes that information.
- **IP suggestions:** lists detected IPv4 addresses and network interfaces, including alternatives that can help when VPNs or virtual adapters are present.
- **Actionable errors:** stops instead of claiming success when model state or server startup cannot be verified safely.
- **Self-contained:** the script embeds its PowerShell implementation inside the `.bat` file. No separate `.ps1`, Python, Node.js, `jq`, or administrator-only installer is required.

## ✅ Requirements

1. A Windows 10 or Windows 11 PC.
2. [LM Studio](https://lmstudio.ai/) installed and launched at least once.
3. The LM Studio CLI (`lms.exe`) available. The script checks common installation locations, including `%USERPROFILE%\.lmstudio\bin\lms.exe`.
4. At least one downloaded local **LLM** in LM Studio.
5. Your Android device and PC connected to the same reachable local network, normally the same Wi-Fi.
6. The **LMSMOB Chat** app installed on Android.

The script does not install LM Studio, download models, create Windows Firewall rules, or change router settings.

## 🚀 Quick start

### 1. Get the files

Download or clone this repository. Keep these two files together:

```text
LMStudio-Android-Host/
├── LMStudio-Android-Host-Pro.bat
└── README.md
```

### 2. Run the script

Double-click `LMStudio-Android-Host-Pro.bat`. If Windows asks whether to run a script you downloaded, confirm only if you trust the copy and its source.

The script will:

1. Find `lms.exe`.
2. Read your downloaded LLM list.
3. Display models as numbered entries.
4. Ask you to select a model or enter `Q` to exit without making changes.
5. Ask for a context length. Press **Enter** to use `4096`.
6. Stop the previous LM Studio server and verify its status when the CLI supports that check.
7. Check that the target port is free before unloading models.
8. Unload existing models and verify the result.
9. Load the model you selected with the API identifier `lmsmob-chat`.
10. Start the API server on port `1234`, then check its availability.
11. Print the PC-local URL, suggested Android URL, model identifier, listener status, and connection checklist.

**Context-length tip:** start with `4096`. Larger contexts can use substantially more memory, and a model may impose a lower maximum than the script's input-validation limit. If loading fails, try a smaller context and read the error shown by LM Studio.

### 3. Configure LMSMOB Chat

Use the values printed at the end of the script. The PC's actual IP address will vary, so **do not copy the example IP below literally**.

| LMSMOB Chat setting | Value |
|---|---|
| **API type** | OpenAI-compatible, if the app asks |
| **Base URL / API URL** | `http://YOUR_PC_LAN_IP:1234/v1` |
| **Model name** | `lmsmob-chat` |
| **API token / key** | Leave blank only when LM Studio API authentication is disabled; otherwise enter a valid LM Studio API token |

Example only:

```text
Base URL: http://192.168.1.100:1234/v1
Model:    lmsmob-chat
```

Use the address marked as the best guess only if it belongs to the same network as your Android. If you have a VPN, virtual adapter, Ethernet, or multiple Wi-Fi interfaces, try the other listed IPv4 candidates too.

### 4. Test the connection

On the PC, open this URL in a browser:

```text
http://127.0.0.1:1234/v1/models
```

On Android, try the same endpoint with your PC's LAN address:

```text
http://YOUR_PC_LAN_IP:1234/v1/models
```

When API authentication is enabled, an authentication response such as `401` or `403` can mean that the server is reachable but needs a valid token. A browser test confirms connectivity, not that every LMSMOB Chat setting is correct.

## 🔐 Security notes

- **Only use this on a trusted network.** Binding to `0.0.0.0` makes the API listen beyond the PC's loopback address. Depending on your network and firewall, other devices may be able to access it.
- **Enable API authentication** in LM Studio's Developer / Server Settings and use a token in the app when the network is not fully trusted. See [LM Studio authentication docs](https://lmstudio.ai/docs/developer/core/authentication).
- If Windows Firewall asks, allow access only on a network profile you trust, usually **Private**. The script does not silently create or alter firewall rules.
- Do **not** port-forward port `1234` on your router or expose this service directly to the public internet.
- The URL uses plain HTTP for a local network. Do not send API tokens or private prompts over an untrusted network.
- Avoid sharing screenshots or logs that reveal private IP addresses, Windows usernames, local model paths, or API tokens.

## 🛠️ Troubleshooting

### “Could not verify the loaded-model state”

The script must distinguish an empty model list from an unknown CLI response. This version captures native command output without treating every stderr message as a fatal PowerShell exception, recognizes explicit no-models messages, and supports empty JSON lists. If this error still appears, open Command Prompt and run:

```bat
"%USERPROFILE%\.lmstudio\bin\lms.exe" ps --json
"%USERPROFILE%\.lmstudio\bin\lms.exe" ps
```

Share the output with sensitive paths or identifiers redacted. Do not delete models or manually change the script's empty-state checks without understanding the CLI output.

### “Could not find the LM Studio CLI”

Open LM Studio at least once. Then check whether this file exists:

```text
%USERPROFILE%\.lmstudio\bin\lms.exe
```

You can also open a new Command Prompt and run `lms --help` if `lms` is on your `PATH`. See the [LM Studio CLI guide](https://lmstudio.ai/docs/cli).

### “Port 1234 is still accepting connections”

Another app may own the port, or LM Studio's server may not have stopped. In Command Prompt, inspect the listener:

```bat
netstat -ano | findstr :1234
```

The final number is a PID. Identify that process in Task Manager before taking action. Do not terminate an unfamiliar process blindly. The script deliberately stops before unloading models if the port remains occupied.

### The model fails to load

- Try the default `4096` context or a smaller value.
- Check LM Studio's error output and model status.
- Make sure the model fits the available system memory and GPU/CPU resources.
- Confirm that the model is downloaded and appears in the script's menu.

The script cannot guarantee that every model will fit in available memory or support every requested context length.

### The PC URL works, but Android cannot connect

1. Confirm both devices are on the same reachable Wi-Fi/LAN, not a guest network with device isolation.
2. Use the PC's active LAN IPv4 address, not `127.0.0.1`, `localhost`, or an unrelated VPN/virtual-adapter address.
3. Check the printed network bind status. The intended listener is `0.0.0.0` on port `1234`.
4. Check Windows Firewall and allow inbound TCP port `1234` only on the trusted private network if required.
5. Turn off VPN routing temporarily for a controlled test, if appropriate for your setup, or test another listed interface address.

### LMSMOB Chat says the model does not exist

Enter the model ID exactly as printed by the script: `lmsmob-chat`. Then inspect `/v1/models` and use an ID shown there if your LM Studio version or client behaves differently. Ensure that you entered the base URL with `/v1` and that the server is still running.

### `401 Unauthorized` or `403 Forbidden`

API authentication may be enabled. Create or copy a valid API token in LM Studio's Server Settings and enter it in LMSMOB Chat. Do not paste the token into GitHub, screenshots, issue reports, or this README.

## ⚙️ Configuration and behavior

| Setting | Current behavior |
|---|---|
| Port | `1234` |
| Server bind | `0.0.0.0` for LAN access |
| API base path | `/v1` |
| Model identifier | `lmsmob-chat` |
| Default context length | `4096` |
| GPU allocation | LM Studio default; script omits `--gpu` |
| Model discovery | `lms ls --llm --json` |
| Loaded-model check | `lms ps --json`, then plain `lms ps` fallback |
| API check | `GET /v1/models` where possible |
| Firewall changes | None made automatically |

The script uses the OpenAI-compatible API path, not LM Studio's separate native REST API path under `/api/v1`.

## 📚 Official documentation

- [LM Studio CLI overview](https://lmstudio.ai/docs/cli)
- [List downloaded models: `lms ls`](https://lmstudio.ai/docs/cli/local-models/ls)
- [List loaded models: `lms ps`](https://lmstudio.ai/docs/cli/local-models/ps)
- [Load and unload models](https://lmstudio.ai/docs/cli/local-models/load)
- [Start the server and bind to the LAN](https://lmstudio.ai/docs/cli/serve/server-start)
- [Check server status](https://lmstudio.ai/docs/cli/serve/server-status)
- [OpenAI-compatible endpoints](https://lmstudio.ai/docs/developer/openai-compat)
- [API authentication](https://lmstudio.ai/docs/developer/core/authentication)

## 🐛 Reporting a bug

Please include:

- Windows version and LM Studio version;
- the exact error text from the script;
- output from `lms ps --json` and `lms server status --json --quiet` when relevant;
- whether `http://127.0.0.1:1234/v1/models` works on the PC.

**Redact** your username, private file paths, private IP details if you prefer not to share them, and any API token. Never upload tokens or credentials in an issue.

## 📄 License

No license is included in this repository by this README. Add a `LICENSE` file before publishing if you intend to grant others permission to reuse, modify, or redistribute the project.
