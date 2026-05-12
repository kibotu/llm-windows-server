# Clone and build MTP-enabled llama.cpp
git clone https://github.com/Indras-Mirror/llama.cpp-mtp
Set-Location llama.cpp-mtp
cmake -B build `
  -DGGML_CUDA=ON `
  -DGGML_NATIVE=ON `
  -DCMAKE_CUDA_ARCHITECTURES=89 `
  -DCMAKE_BUILD_TYPE=Release

cmake --build build `
  --config Release `
  -j $env:NUMBER_OF_PROCESSORS `
  --target llama-server

# Run with MTP + MoE offload (optimized for RTX 4080 16GB + 96GB RAM)
# .\build\bin\Release\llama-server.exe `
#   -m ..\..\models\Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-Q4_K_M.gguf `
#   --spec-type mtp `
#   --spec-draft-n-max 2 `
#   -ctk q4_0 `
#   -ctv q4_0 `
#   -c 65536 `
#   -ngl 99 `
#   --flash-attn on `
#   --mlock `
#   --cpu-moe `
#   -t 10 `
#   -b 2048 `
#   -ub 2048 `
#   -np 1 `
#   --jinja `
#   --cont-batching `
#   --metrics `
#   --host 0.0.0.0 `
#   --port 8899 `
#   --no-mmap

# Run with MTP + MoE offload (optimized for RTX 4080 16GB + 96GB RAM)
.\build\bin\Release\llama-server.exe `
  -m ..\..\models\Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-Q4_K_M.gguf `
  -ctk q4_0 `
  -ctv q4_0 `
  -c 131072 `
  -ngl 99 `
  --flash-attn on `
  --mlock `
  --cpu-moe `
  -t 10 `
  -b 2048 `
  -ub 2048 `
  -parallel 1 `
  --jinja `
  --cont-batching `
  --reasoning on `
  --reasoning-format deepseek `
  --chat-template-kwargs '{\"preserve_thinking\":true,\"enable_thinking\":true}' `
  --metrics `
  --numa distribute `
  --host 0.0.0.0 `
  --port 8899 `
  --no-mmap

# Alternative: Longer context with q4_0 KV cache (64K context)
# .\build\bin\Debug\llama-server.exe `
#   -m ..\..\models\Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-Q4_K_M.gguf `
#   --spec-type mtp --spec-draft-n-max 2 `
#   -ctk q4_0 -ctv q4_0 `
#   -c 65536 -ngl 99 `
#   --flash-attn on --mlock `
#   --cpu-moe `
#   -t 8 -b 2048 -ub 512 -np 1 `
#   --jinja `
#   --chat-template-kwargs '{\"enable_thinking\": true, \"preserve_thinking\": true}' `
#   --reasoning-budget 4096 `
#   --cont-batching `
#   --metrics `
#   --host 0.0.0.0 --port 8888 `
#   --no-warmup --no-mmap
