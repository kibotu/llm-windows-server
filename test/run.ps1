# Clone and build MTP-enabled llama.cpp
git clone https://github.com/ggml-org/llama.cpp.git
Set-Location llama.cpp
cmake -B build `
  -DGGML_CUDA=ON `
  -DGGML_NATIVE=ON `
  -DCMAKE_CUDA_ARCHITECTURES=89 `
  -DCMAKE_BUILD_TYPE=Release

cmake --build build `
  --config Release `
  -j $env:NUMBER_OF_PROCESSORS `
  --target llama-server

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
