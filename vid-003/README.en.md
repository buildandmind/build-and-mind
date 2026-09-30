# Choosing a GPU for local AI

This folder accompanies the BUILD & MIND video about GPU memory and performance
for local text models.

- [`resultats-principaux.csv`](resultats-principaux.csv) contains the medians
  measured with Qwen3-14B Q4_K_M.
- [`resultats-quantification.csv`](resultats-quantification.csv) summarizes a
  limited comparison of two quantizations of a 27B model.
- [`prompts/prompt-court.txt`](prompts/prompt-court.txt) is the short input used
  for generation measurements.
- [`prompts/questions-qualite.json`](prompts/questions-qualite.json) contains
  the five quantization-test questions.

GGUF weights are not distributed here. Obtain a model from a source you trust
and record its exact name, quantization, size and hash with your results. The
names below identify the files that were actually measured; this folder does
not attribute their publication to an unverified upstream repository.

## What was compared

The main measurements used the same `Qwen3-14B-Q4_K_M.gguf` file
(9,001,752,960 bytes, SHA-256
`500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0`),
llama.cpp commit `ece963f41b0b02d7a0d61436ae365762c073a4c8`, an 8192-token
context, `-ngl 99`, `--split-mode layer`, `--parallel 1`, temperature 0 and
seed 1234. One warm-up was discarded and the median of three runs was kept.
In the CSV, each `premier_token_s_un_passage_streame_separe` value comes from
one additional streamed request. It is not a median of the three measured runs.

The RTX 5070 Ti ran on Windows 11 with CUDA. The AMD cards ran on Ubuntu with
HIP/ROCm. Drivers, CPUs and test dates also differ. These results compare the
complete installations; they do not isolate CUDA, ROCm, the GPU or the CPU as a
single cause.

| Tier | GPU(s) | System and backend | Date |
|---|---|---|---|
| T1 | RTX 5070 Ti, 16 GB | Windows 11 build 26200, CUDA 13.3.33, driver 596.36 | 10 September 2026 |
| T2 | RX 9070 XT, 16 GB | Ubuntu, HIP/ROCm 7.1 | 7 September 2026 |
| T3 | R9700, 32 GB | Ubuntu, HIP/ROCm 7.1 | 7 September 2026 |
| T4 | 3 × R9700 + 1 × RX 9070 XT, 112 GB combined | Ubuntu, HIP/ROCm 7.1 | 7 September 2026 |

The long prompt contained a wholly fictional network document. That working
corpus is not published. Its SHA-256 was
`e01f0c1cf25b49f8cf05878609ee47916b76952ee4170295a40eae8c9cad09e9`
and llama.cpp counted 6609 tokens in this campaign. You can repeat the method
with your own document, but that will not exactly reproduce our run.

These commands document our method. We do not guarantee the same results on a
different machine, and we have not validated every combination of operating
system, driver and llama.cpp build.

## Start llama.cpp

Replace paths and GPU indexes with values for your machine. First make sure
port 8080 is free and no other workload is using the GPU. On HIP, first compare
`amd-smi list` with `llama-server --list-devices`: indexes and GPU order can
change between machines or boots. One value in `HIP_VISIBLE_DEVICES` exposes
one selected GPU. To expose all intended GPUs, list every confirmed index,
comma-separated and in the order reported for your machine.

The Linux command below is a **single-GPU example**. It does not reproduce T4.
Our T4 result used four GPUs with an order and layer distribution specific to
the tested workstation. This package does not provide a portable multi-GPU T4
reproduction command.

Linux, HIP build:

```bash
export HIP_VISIBLE_DEVICES=0
export ROCBLAS_USE_HIPBLASLT=0
export GGML_HIP_NO_VMM=1

./llama-server \
  -m /path/to/Qwen3-14B-Q4_K_M.gguf \
  -c 8192 -ngl 99 --split-mode layer --parallel 1 \
  --host 127.0.0.1 --port 8080 --no-warmup
```

Windows PowerShell, CUDA build:

```powershell
$env:CUDA_VISIBLE_DEVICES = "0"
& .\llama-server.exe `
  -m C:\path\to\Qwen3-14B-Q4_K_M.gguf `
  -c 8192 -ngl 99 --split-mode layer --parallel 1 `
  --host 127.0.0.1 --port 8080 --no-warmup
```

Check the server log for the expected layer placement. A model that starts may
still use shared system memory, so also inspect dedicated GPU and system memory.

## Send the short prompt

The test used the raw `/completion` API without a chat template. From this
folder, the following command only requires Python 3:

```bash
python3 - <<'PY'
import json
import urllib.request
from pathlib import Path

payload = {
    "prompt": Path("prompts/prompt-court.txt").read_text(encoding="utf-8"),
    "n_predict": 256,
    "temperature": 0,
    "seed": 1234,
    "cache_prompt": False,
    "stream": False,
}
request = urllib.request.Request(
    "http://127.0.0.1:8080/completion",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=600) as response:
    result = json.load(response)
print(json.dumps(result.get("timings", {}), indent=2))
PY
```

This request is deliberately non-streaming. It reports llama.cpp engine timings
but does not measure time to first token. The CSV's first-token column came from
the separate streamed requests described above.

The equivalent Windows PowerShell request is:

```powershell
$Payload = @{
  prompt = Get-Content .\prompts\prompt-court.txt -Raw
  n_predict = 256
  temperature = 0
  seed = 1234
  cache_prompt = $false
  stream = $false
} | ConvertTo-Json
$Result = Invoke-RestMethod `
  -Uri http://127.0.0.1:8080/completion `
  -Method Post -ContentType "application/json" -Body $Payload
$Result.timings
```

Discard one warm-up, then run the same request three times. Use the median of
`predicted_per_second` for generation and `prompt_per_second` for input
processing. Compare machines only with the same file, prompt and settings.

## Quantization-test limits

The second CSV compares `Huihui-Qwen3.8-27B-abliterated-Q6_K.gguf` on a
32 GB R9700 with `Huihui-Qwen3.8-27B-abliterated-Q4_K.gguf` on a 16 GB
RX 9070 XT. Five responses per version were scored blind with criteria fixed
before reading. Both sets scored 20/20.

This only means that no difference was found on those five simple questions and
that rubric. It is not a general quality verdict. Because the GPUs differ, it
does not isolate the quantization's effect on speed. Test your own tasks before
buying hardware.
