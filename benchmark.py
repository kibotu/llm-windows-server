#!/usr/bin/env python3
"""
High-load benchmark suite for LLM server with large context windows.
Tests throughput, latency, memory usage, and context handling up to 128k tokens.
"""

import argparse
import asyncio
import json
import time
import statistics
from dataclasses import dataclass, asdict
from datetime import datetime
from typing import List, Dict, Any, Optional
import aiohttp
import psutil
from pathlib import Path


@dataclass
class BenchmarkResult:
    """Results from a single benchmark run."""
    test_name: str
    timestamp: str
    duration_seconds: float
    total_requests: int
    successful_requests: int
    failed_requests: int
    requests_per_second: float
    avg_latency_ms: float
    p50_latency_ms: float
    p95_latency_ms: float
    p99_latency_ms: float
    max_latency_ms: float
    min_latency_ms: float
    total_tokens_generated: int
    tokens_per_second: float
    avg_prompt_tokens: float
    avg_completion_tokens: float
    errors: List[str]
    memory_stats: Dict[str, Any]


@dataclass
class RequestResult:
    """Result from a single request."""
    success: bool
    latency_ms: float
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    error: Optional[str] = None
    ttft_ms: Optional[float] = None  # Time to first token


class LLMBenchmark:
    """Benchmark suite for LLM server."""
    
    def __init__(self, base_url: str, timeout: int = 300):
        self.base_url = base_url.rstrip('/')
        self.timeout = timeout
        self.results: List[BenchmarkResult] = []
    
    def generate_text(self, token_count: int) -> str:
        """Generate text with approximately the specified token count."""
        # Rough estimate: 1 token ≈ 4 characters for English text
        words_needed = token_count * 4 // 5  # Average word length ~5 chars
        
        # Use varied text to avoid compression/caching effects
        base_text = [
            "The quick brown fox jumps over the lazy dog.",
            "Artificial intelligence and machine learning are transforming technology.",
            "Deep neural networks process information through multiple layers.",
            "Natural language processing enables computers to understand human language.",
            "Large language models can generate coherent and contextual text.",
            "Transformer architectures revolutionized the field of AI.",
            "Context windows allow models to process longer sequences of text.",
            "GPU acceleration enables faster training and inference.",
            "Quantization reduces model size while maintaining performance.",
            "Attention mechanisms help models focus on relevant information."
        ]
        
        result = []
        word_count = 0
        idx = 0
        
        while word_count < words_needed:
            result.append(base_text[idx % len(base_text)])
            word_count += len(base_text[idx % len(base_text)].split())
            idx += 1
        
        return " ".join(result)
    
    async def make_request(
        self,
        session: aiohttp.ClientSession,
        prompt: str,
        max_tokens: int = 100,
        stream: bool = False
    ) -> RequestResult:
        """Make a single request to the LLM server."""
        start_time = time.time()
        ttft = None
        
        try:
            payload = {
                "prompt": prompt,
                "max_tokens": max_tokens,
                "temperature": 0.7,
                "stream": stream
            }
            
            async with session.post(
                f"{self.base_url}/completion",
                json=payload,
                timeout=aiohttp.ClientTimeout(total=self.timeout)
            ) as response:
                
                if stream:
                    # Handle streaming response
                    completion_tokens = 0
                    first_token_time = None
                    last_data = None
                    
                    async for line in response.content:
                        if first_token_time is None:
                            first_token_time = time.time()
                            ttft = (first_token_time - start_time) * 1000
                        
                        line_str = line.decode('utf-8').strip()
                        if line_str.startswith('data: ') and line_str != 'data: [DONE]':
                            try:
                                data = json.loads(line_str[6:])
                                last_data = data
                                if 'content' in data:
                                    completion_tokens += 1
                            except json.JSONDecodeError:
                                pass
                    
                    end_time = time.time()
                    latency_ms = (end_time - start_time) * 1000
                    
                    # Extract usage from last data chunk
                    if last_data and 'usage' in last_data:
                        usage = last_data['usage']
                        return RequestResult(
                            success=True,
                            latency_ms=latency_ms,
                            prompt_tokens=usage.get('prompt_tokens', 0),
                            completion_tokens=usage.get('completion_tokens', 0),
                            total_tokens=usage.get('total_tokens', 0),
                            ttft_ms=ttft
                        )
                    else:
                        # Fallback if no usage data
                        return RequestResult(
                            success=True,
                            latency_ms=latency_ms,
                            prompt_tokens=len(prompt.split()) * 1.3,  # Rough estimate
                            completion_tokens=completion_tokens,
                            total_tokens=len(prompt.split()) * 1.3 + completion_tokens,
                            ttft_ms=ttft
                        )
                else:
                    # Handle non-streaming response
                    data = await response.json()
                    end_time = time.time()
                    latency_ms = (end_time - start_time) * 1000
                    
                    if response.status == 200:
                        usage = data.get('usage', {})
                        return RequestResult(
                            success=True,
                            latency_ms=latency_ms,
                            prompt_tokens=usage.get('prompt_tokens', 0),
                            completion_tokens=usage.get('completion_tokens', 0),
                            total_tokens=usage.get('total_tokens', 0)
                        )
                    else:
                        return RequestResult(
                            success=False,
                            latency_ms=latency_ms,
                            prompt_tokens=0,
                            completion_tokens=0,
                            total_tokens=0,
                            error=f"HTTP {response.status}: {data}"
                        )
        
        except asyncio.TimeoutError:
            end_time = time.time()
            return RequestResult(
                success=False,
                latency_ms=(end_time - start_time) * 1000,
                prompt_tokens=0,
                completion_tokens=0,
                total_tokens=0,
                error="Request timeout"
            )
        except Exception as e:
            end_time = time.time()
            return RequestResult(
                success=False,
                latency_ms=(end_time - start_time) * 1000,
                prompt_tokens=0,
                completion_tokens=0,
                total_tokens=0,
                error=str(e)
            )
    
    def get_memory_stats(self) -> Dict[str, Any]:
        """Get current memory statistics."""
        mem = psutil.virtual_memory()
        return {
            "total_gb": round(mem.total / (1024**3), 2),
            "available_gb": round(mem.available / (1024**3), 2),
            "used_gb": round(mem.used / (1024**3), 2),
            "percent": mem.percent
        }
    
    def analyze_results(
        self,
        test_name: str,
        results: List[RequestResult],
        duration: float
    ) -> BenchmarkResult:
        """Analyze benchmark results and compute statistics."""
        successful = [r for r in results if r.success]
        failed = [r for r in results if not r.success]
        
        if not successful:
            return BenchmarkResult(
                test_name=test_name,
                timestamp=datetime.now().isoformat(),
                duration_seconds=duration,
                total_requests=len(results),
                successful_requests=0,
                failed_requests=len(failed),
                requests_per_second=0,
                avg_latency_ms=0,
                p50_latency_ms=0,
                p95_latency_ms=0,
                p99_latency_ms=0,
                max_latency_ms=0,
                min_latency_ms=0,
                total_tokens_generated=0,
                tokens_per_second=0,
                avg_prompt_tokens=0,
                avg_completion_tokens=0,
                errors=[r.error for r in failed if r.error],
                memory_stats=self.get_memory_stats()
            )
        
        latencies = [r.latency_ms for r in successful]
        latencies.sort()
        
        total_tokens = sum(r.total_tokens for r in successful)
        total_prompt = sum(r.prompt_tokens for r in successful)
        total_completion = sum(r.completion_tokens for r in successful)
        
        return BenchmarkResult(
            test_name=test_name,
            timestamp=datetime.now().isoformat(),
            duration_seconds=duration,
            total_requests=len(results),
            successful_requests=len(successful),
            failed_requests=len(failed),
            requests_per_second=len(successful) / duration if duration > 0 else 0,
            avg_latency_ms=statistics.mean(latencies),
            p50_latency_ms=latencies[len(latencies) // 2],
            p95_latency_ms=latencies[int(len(latencies) * 0.95)],
            p99_latency_ms=latencies[int(len(latencies) * 0.99)],
            max_latency_ms=max(latencies),
            min_latency_ms=min(latencies),
            total_tokens_generated=total_tokens,
            tokens_per_second=total_tokens / duration if duration > 0 else 0,
            avg_prompt_tokens=total_prompt / len(successful),
            avg_completion_tokens=total_completion / len(successful),
            errors=[r.error for r in failed if r.error][:10],  # Limit to 10 errors
            memory_stats=self.get_memory_stats()
        )
    
    async def run_concurrent_test(
        self,
        test_name: str,
        num_requests: int,
        concurrency: int,
        prompt_tokens: int,
        max_tokens: int = 100,
        stream: bool = False
    ):
        """Run concurrent requests test."""
        print(f"\n{'='*80}")
        print(f"Running: {test_name}")
        print(f"Requests: {num_requests}, Concurrency: {concurrency}")
        print(f"Prompt tokens: ~{prompt_tokens}, Max completion: {max_tokens}")
        print(f"Streaming: {stream}")
        print(f"{'='*80}\n")
        
        prompt = self.generate_text(prompt_tokens)
        results = []
        
        async with aiohttp.ClientSession() as session:
            start_time = time.time()
            
            # Create semaphore for concurrency control
            semaphore = asyncio.Semaphore(concurrency)
            
            async def bounded_request():
                async with semaphore:
                    return await self.make_request(session, prompt, max_tokens, stream)
            
            # Execute all requests
            tasks = [bounded_request() for _ in range(num_requests)]
            results = await asyncio.gather(*tasks)
            
            end_time = time.time()
            duration = end_time - start_time
        
        # Analyze results
        benchmark_result = self.analyze_results(test_name, results, duration)
        self.results.append(benchmark_result)
        
        # Print summary
        self.print_result(benchmark_result)
        
        return benchmark_result
    
    async def run_sustained_load_test(
        self,
        test_name: str,
        duration_seconds: int,
        requests_per_second: int,
        prompt_tokens: int,
        max_tokens: int = 100
    ):
        """Run sustained load test for a specific duration."""
        print(f"\n{'='*80}")
        print(f"Running: {test_name}")
        print(f"Duration: {duration_seconds}s, Target RPS: {requests_per_second}")
        print(f"Prompt tokens: ~{prompt_tokens}, Max completion: {max_tokens}")
        print(f"{'='*80}\n")
        
        prompt = self.generate_text(prompt_tokens)
        results = []
        
        async with aiohttp.ClientSession() as session:
            start_time = time.time()
            request_interval = 1.0 / requests_per_second
            
            while time.time() - start_time < duration_seconds:
                batch_start = time.time()
                
                # Send batch of requests
                result = await self.make_request(session, prompt, max_tokens, stream=False)
                results.append(result)
                
                # Wait to maintain target RPS
                elapsed = time.time() - batch_start
                if elapsed < request_interval:
                    await asyncio.sleep(request_interval - elapsed)
                
                # Progress indicator
                if len(results) % 10 == 0:
                    print(f"Progress: {len(results)} requests, "
                          f"{time.time() - start_time:.1f}s elapsed")
            
            end_time = time.time()
            duration = end_time - start_time
        
        # Analyze results
        benchmark_result = self.analyze_results(test_name, results, duration)
        self.results.append(benchmark_result)
        
        # Print summary
        self.print_result(benchmark_result)
        
        return benchmark_result
    
    async def run_context_scaling_test(self):
        """Test performance across different context sizes."""
        print(f"\n{'='*80}")
        print("CONTEXT SCALING TEST")
        print(f"{'='*80}\n")
        
        # Test different context sizes
        context_sizes = [1000, 5000, 10000, 20000, 40000, 60000, 80000, 100000, 120000]
        
        for size in context_sizes:
            await self.run_concurrent_test(
                test_name=f"Context {size} tokens",
                num_requests=5,
                concurrency=1,
                prompt_tokens=size,
                max_tokens=100,
                stream=False
            )
            # Small delay between tests
            await asyncio.sleep(2)
    
    def print_result(self, result: BenchmarkResult):
        """Print formatted benchmark result."""
        print(f"\nResults for: {result.test_name}")
        print("-"*80)
        print(f"Duration:              {result.duration_seconds:.2f}s")
        print(f"Total Requests:        {result.total_requests}")
        print(f"Successful:            {result.successful_requests}")
        print(f"Failed:                {result.failed_requests}")
        print(f"Requests/sec:          {result.requests_per_second:.2f}")
        print(f"\nLatency Statistics (ms):")
        print(f"  Average:             {result.avg_latency_ms:.2f}")
        print(f"  P50:                 {result.p50_latency_ms:.2f}")
        print(f"  P95:                 {result.p95_latency_ms:.2f}")
        print(f"  P99:                 {result.p99_latency_ms:.2f}")
        print(f"  Min:                 {result.min_latency_ms:.2f}")
        print(f"  Max:                 {result.max_latency_ms:.2f}")
        print(f"\nToken Statistics:")
        print(f"  Total tokens:        {result.total_tokens_generated}")
        print(f"  Tokens/sec:          {result.tokens_per_second:.2f}")
        print(f"  Avg prompt tokens:   {result.avg_prompt_tokens:.0f}")
        print(f"  Avg completion:      {result.avg_completion_tokens:.0f}")
        print(f"\nMemory Usage:")
        print(f"  Used:                {result.memory_stats['used_gb']} GB "
              f"({result.memory_stats['percent']:.1f}%)")
        print(f"  Available:           {result.memory_stats['available_gb']} GB")
        
        if result.errors:
            print(f"\nErrors (showing first 10):")
            for error in result.errors[:10]:
                print(f"  - {error}")
        
        print("-"*80 + "\n")
    
    def save_results(self, output_file: str):
        """Save all benchmark results to JSON file."""
        data = {
            "benchmark_run": datetime.now().isoformat(),
            "results": [asdict(r) for r in self.results]
        }
        
        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)
        
        print(f"\nResults saved to: {output_file}")
    
    def print_summary(self):
        """Print summary of all benchmark results."""
        print(f"\n{'='*80}")
        print("BENCHMARK SUMMARY")
        print(f"{'='*80}\n")
        
        for result in self.results:
            print(f"{result.test_name:40s} | "
                  f"RPS: {result.requests_per_second:6.2f} | "
                  f"Latency: {result.avg_latency_ms:7.2f}ms | "
                  f"Tokens/s: {result.tokens_per_second:6.2f}")
        
        print(f"\n{'='*80}\n")


async def main():
    parser = argparse.ArgumentParser(
        description="Benchmark LLM server with large context windows"
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8899",
        help="Base URL of the LLM server (default: http://localhost:8899)"
    )
    parser.add_argument(
        "--test",
        choices=["quick", "standard", "stress", "context-scaling", "all"],
        default="standard",
        help="Test suite to run (default: standard)"
    )
    parser.add_argument(
        "--output",
        default="benchmark_results.json",
        help="Output file for results (default: benchmark_results.json)"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Request timeout in seconds (default: 300)"
    )
    
    args = parser.parse_args()
    
    benchmark = LLMBenchmark(args.url, args.timeout)
    
    print(f"\n{'='*80}")
    print(f"LLM Server Benchmark Suite")
    print(f"Target: {args.url}")
    print(f"Test Suite: {args.test}")
    print(f"{'='*80}\n")
    
    try:
        if args.test in ["quick", "all"]:
            # Quick smoke tests
            await benchmark.run_concurrent_test(
                "Quick: Small context (1k tokens)",
                num_requests=1,
                concurrency=1,
                prompt_tokens=10000,
                max_tokens=50
            )
        
        if args.test in ["standard", "all"]:
            # Standard benchmark suite
            await benchmark.run_concurrent_test(
                "Standard: Medium context (10k tokens)",
                num_requests=20,
                concurrency=5,
                prompt_tokens=10000,
                max_tokens=100
            )
            
            await benchmark.run_concurrent_test(
                "Standard: Large context (50k tokens)",
                num_requests=10,
                concurrency=3,
                prompt_tokens=50000,
                max_tokens=100
            )
            
            await benchmark.run_concurrent_test(
                "Standard: Very large context (100k tokens)",
                num_requests=5,
                concurrency=2,
                prompt_tokens=100000,
                max_tokens=100
            )
        
        if args.test in ["stress", "all"]:
            # Stress tests
            await benchmark.run_concurrent_test(
                "Stress: High concurrency (20 concurrent)",
                num_requests=50,
                concurrency=20,
                prompt_tokens=5000,
                max_tokens=50
            )
            
            await benchmark.run_sustained_load_test(
                "Stress: Sustained load (60s, 2 RPS)",
                duration_seconds=60,
                requests_per_second=2,
                prompt_tokens=10000,
                max_tokens=100
            )
            
            await benchmark.run_concurrent_test(
                "Stress: Maximum context (128k tokens)",
                num_requests=3,
                concurrency=1,
                prompt_tokens=120000,
                max_tokens=100
            )
        
        if args.test in ["context-scaling", "all"]:
            # Context scaling test
            await benchmark.run_context_scaling_test()
        
        # Print summary and save results
        benchmark.print_summary()
        benchmark.save_results(args.output)
        
        print("\nBenchmark completed successfully!")
        
    except KeyboardInterrupt:
        print("\n\nBenchmark interrupted by user")
        if benchmark.results:
            benchmark.print_summary()
            benchmark.save_results(args.output)
    except Exception as e:
        print(f"\n\nBenchmark failed with error: {e}")
        import traceback
        traceback.print_exc()
        if benchmark.results:
            benchmark.print_summary()
            benchmark.save_results(args.output)


if __name__ == "__main__":
    asyncio.run(main())
