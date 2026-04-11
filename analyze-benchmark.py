#!/usr/bin/env python3
"""
Analyze and visualize benchmark results.
Generates reports and charts from benchmark JSON output.
"""

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Any


def load_results(filepath: str) -> Dict[str, Any]:
    """Load benchmark results from JSON file."""
    with open(filepath, 'r') as f:
        return json.load(f)


def format_duration(seconds: float) -> str:
    """Format duration in human-readable format."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    elif seconds < 3600:
        return f"{seconds/60:.1f}m"
    else:
        return f"{seconds/3600:.1f}h"


def format_bytes(bytes_val: float) -> str:
    """Format bytes in human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024.0:
            return f"{bytes_val:.2f} {unit}"
        bytes_val /= 1024.0
    return f"{bytes_val:.2f} PB"


def print_summary_table(results: List[Dict[str, Any]]):
    """Print a summary table of all benchmark results."""
    print("\n" + "="*120)
    print("BENCHMARK RESULTS SUMMARY")
    print("="*120)
    print(f"{'Test Name':<45} {'RPS':>8} {'Latency (ms)':>15} {'Tokens/s':>12} {'Success':>8} {'Memory':>12}")
    print(f"{'':45} {'':>8} {'Avg/P95/P99':>15} {'':>12} {'Rate':>8} {'Used':>12}")
    print("-"*120)
    
    for result in results:
        test_name = result['test_name'][:44]
        rps = result['requests_per_second']
        avg_lat = result['avg_latency_ms']
        p95_lat = result['p95_latency_ms']
        p99_lat = result['p99_latency_ms']
        tokens_per_sec = result['tokens_per_second']
        success_rate = (result['successful_requests'] / result['total_requests'] * 100) if result['total_requests'] > 0 else 0
        mem_used = result['memory_stats']['used_gb']
        
        latency_str = f"{avg_lat:.0f}/{p95_lat:.0f}/{p99_lat:.0f}"
        
        print(f"{test_name:<45} {rps:>8.2f} {latency_str:>15} {tokens_per_sec:>12.1f} {success_rate:>7.1f}% {mem_used:>10.1f}GB")
    
    print("="*120)


def print_detailed_report(result: Dict[str, Any]):
    """Print detailed report for a single benchmark result."""
    print("\n" + "="*100)
    print(f"DETAILED REPORT: {result['test_name']}")
    print("="*100)
    
    # Basic info
    print(f"\nTimestamp:           {result['timestamp']}")
    print(f"Duration:            {format_duration(result['duration_seconds'])}")
    
    # Request statistics
    print(f"\nRequest Statistics:")
    print(f"  Total Requests:    {result['total_requests']}")
    print(f"  Successful:        {result['successful_requests']} ({result['successful_requests']/result['total_requests']*100:.1f}%)")
    print(f"  Failed:            {result['failed_requests']} ({result['failed_requests']/result['total_requests']*100:.1f}%)")
    print(f"  Throughput:        {result['requests_per_second']:.2f} requests/sec")
    
    # Latency statistics
    print(f"\nLatency Statistics (milliseconds):")
    print(f"  Minimum:           {result['min_latency_ms']:.2f} ms")
    print(f"  Average:           {result['avg_latency_ms']:.2f} ms")
    print(f"  Median (P50):      {result['p50_latency_ms']:.2f} ms")
    print(f"  P95:               {result['p95_latency_ms']:.2f} ms")
    print(f"  P99:               {result['p99_latency_ms']:.2f} ms")
    print(f"  Maximum:           {result['max_latency_ms']:.2f} ms")
    
    # Latency distribution visualization
    avg = result['avg_latency_ms']
    p50 = result['p50_latency_ms']
    p95 = result['p95_latency_ms']
    p99 = result['p99_latency_ms']
    max_val = result['max_latency_ms']
    
    print(f"\n  Distribution:")
    scale = 60 / max_val if max_val > 0 else 1
    print(f"    Min  {result['min_latency_ms']:>8.0f}ms |")
    print(f"    Avg  {avg:>8.0f}ms |{'█' * int(avg * scale)}")
    print(f"    P50  {p50:>8.0f}ms |{'█' * int(p50 * scale)}")
    print(f"    P95  {p95:>8.0f}ms |{'█' * int(p95 * scale)}")
    print(f"    P99  {p99:>8.0f}ms |{'█' * int(p99 * scale)}")
    print(f"    Max  {max_val:>8.0f}ms |{'█' * int(max_val * scale)}")
    
    # Token statistics
    print(f"\nToken Statistics:")
    print(f"  Total Tokens:      {result['total_tokens_generated']:,}")
    print(f"  Throughput:        {result['tokens_per_second']:.2f} tokens/sec")
    print(f"  Avg Prompt:        {result['avg_prompt_tokens']:.0f} tokens")
    print(f"  Avg Completion:    {result['avg_completion_tokens']:.0f} tokens")
    
    # Memory statistics
    mem = result['memory_stats']
    print(f"\nMemory Usage:")
    print(f"  Total RAM:         {mem['total_gb']:.2f} GB")
    print(f"  Used RAM:          {mem['used_gb']:.2f} GB ({mem['percent']:.1f}%)")
    print(f"  Available RAM:     {mem['available_gb']:.2f} GB")
    
    # Memory usage bar
    used_pct = mem['percent']
    bar_length = 50
    filled = int(bar_length * used_pct / 100)
    bar = '█' * filled + '░' * (bar_length - filled)
    print(f"  Usage Bar:         [{bar}] {used_pct:.1f}%")
    
    # Errors
    if result['errors']:
        print(f"\nErrors (showing first 10):")
        for i, error in enumerate(result['errors'][:10], 1):
            print(f"  {i}. {error}")
    
    print("="*100)


def analyze_context_scaling(results: List[Dict[str, Any]]):
    """Analyze context scaling performance."""
    # Filter context scaling tests
    context_tests = [r for r in results if 'Context' in r['test_name'] or 'context' in r['test_name'].lower()]
    
    if not context_tests:
        print("\nNo context scaling tests found.")
        return
    
    print("\n" + "="*100)
    print("CONTEXT SCALING ANALYSIS")
    print("="*100)
    
    print(f"\n{'Context Size':<15} {'RPS':>10} {'Latency (ms)':>15} {'Tokens/s':>12} {'Memory (GB)':>12}")
    print(f"{'':15} {'':>10} {'P50/P95/P99':>15} {'':>12} {'Used':>12}")
    print("-"*100)
    
    for result in sorted(context_tests, key=lambda x: x['avg_prompt_tokens']):
        context_size = f"{int(result['avg_prompt_tokens']):,}"
        rps = result['requests_per_second']
        p50 = result['p50_latency_ms']
        p95 = result['p95_latency_ms']
        p99 = result['p99_latency_ms']
        tokens_per_sec = result['tokens_per_second']
        mem_used = result['memory_stats']['used_gb']
        
        latency_str = f"{p50:.0f}/{p95:.0f}/{p99:.0f}"
        
        print(f"{context_size:<15} {rps:>10.2f} {latency_str:>15} {tokens_per_sec:>12.1f} {mem_used:>12.1f}")
    
    print("="*100)
    
    # Performance degradation analysis
    if len(context_tests) >= 2:
        print("\nPerformance Degradation:")
        baseline = context_tests[0]
        
        for result in context_tests[1:]:
            context_size = int(result['avg_prompt_tokens'])
            rps_change = ((result['requests_per_second'] - baseline['requests_per_second']) / 
                         baseline['requests_per_second'] * 100)
            latency_change = ((result['avg_latency_ms'] - baseline['avg_latency_ms']) / 
                            baseline['avg_latency_ms'] * 100)
            
            print(f"  {context_size:>6,} tokens: RPS {rps_change:+.1f}%, Latency {latency_change:+.1f}%")


def generate_recommendations(results: List[Dict[str, Any]]):
    """Generate performance recommendations based on results."""
    print("\n" + "="*100)
    print("PERFORMANCE RECOMMENDATIONS")
    print("="*100)
    
    recommendations = []
    
    # Analyze overall performance
    avg_success_rate = sum(r['successful_requests'] for r in results) / sum(r['total_requests'] for r in results) * 100
    if avg_success_rate < 95:
        recommendations.append(
            f"⚠️  Low success rate ({avg_success_rate:.1f}%). Consider:\n"
            "   - Increasing timeout values\n"
            "   - Reducing concurrency\n"
            "   - Checking server logs for errors"
        )
    
    # Check for high latency
    high_latency_tests = [r for r in results if r['p95_latency_ms'] > 10000]
    if high_latency_tests:
        recommendations.append(
            f"⚠️  High latency detected in {len(high_latency_tests)} test(s). Consider:\n"
            "   - Reducing context size\n"
            "   - Enabling KV cache quantization (already enabled: -ctk q4_0)\n"
            "   - Reducing batch size"
        )
    
    # Check memory usage
    high_mem_tests = [r for r in results if r['memory_stats']['percent'] > 90]
    if high_mem_tests:
        recommendations.append(
            f"⚠️  High memory usage (>90%) in {len(high_mem_tests)} test(s). Risk of OOM:\n"
            "   - Reduce context size\n"
            "   - Close other applications\n"
            "   - Consider adding swap space"
        )
    
    # Check for VRAM spillover (estimated)
    large_context_tests = [r for r in results if r['avg_prompt_tokens'] > 80000]
    if large_context_tests:
        slow_tests = [r for r in large_context_tests if r['tokens_per_second'] < 30]
        if slow_tests:
            recommendations.append(
                f"⚠️  Slow token generation with large contexts. Likely VRAM spillover:\n"
                "   - Current setup: 16GB VRAM, ~138k token limit\n"
                "   - Contexts >100k may spill to system RAM\n"
                "   - Consider reducing max context or upgrading GPU"
            )
    
    # Performance is good
    if not recommendations:
        recommendations.append(
            "✅ Performance looks good! Your system is handling the load well.\n"
            "   - Success rate is high\n"
            "   - Latencies are reasonable\n"
            "   - Memory usage is under control"
        )
    
    for i, rec in enumerate(recommendations, 1):
        print(f"\n{i}. {rec}")
    
    print("\n" + "="*100)


def main():
    parser = argparse.ArgumentParser(
        description="Analyze and visualize LLM benchmark results"
    )
    parser.add_argument(
        "input",
        help="Input JSON file with benchmark results"
    )
    parser.add_argument(
        "--detailed",
        action="store_true",
        help="Show detailed report for each test"
    )
    parser.add_argument(
        "--context-scaling",
        action="store_true",
        help="Show context scaling analysis"
    )
    parser.add_argument(
        "--recommendations",
        action="store_true",
        help="Generate performance recommendations"
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Show all reports"
    )
    
    args = parser.parse_args()
    
    # Load results
    try:
        data = load_results(args.input)
    except FileNotFoundError:
        print(f"Error: File not found: {args.input}")
        return 1
    except json.JSONDecodeError:
        print(f"Error: Invalid JSON file: {args.input}")
        return 1
    
    results = data.get('results', [])
    if not results:
        print("No results found in file.")
        return 1
    
    # Print header
    print("\n" + "="*100)
    print(f"BENCHMARK ANALYSIS: {args.input}")
    print(f"Benchmark Run: {data.get('benchmark_run', 'Unknown')}")
    print(f"Total Tests: {len(results)}")
    print("="*100)
    
    # Always show summary table
    print_summary_table(results)
    
    # Detailed reports
    if args.detailed or args.all:
        for result in results:
            print_detailed_report(result)
    
    # Context scaling analysis
    if args.context_scaling or args.all:
        analyze_context_scaling(results)
    
    # Recommendations
    if args.recommendations or args.all:
        generate_recommendations(results)
    
    return 0


if __name__ == "__main__":
    exit(main())
