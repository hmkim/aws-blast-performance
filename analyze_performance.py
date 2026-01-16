#!/usr/bin/env python3
import boto3
import json
import re
from datetime import datetime
from collections import defaultdict

def extract_metrics_from_logs(log_group, region='us-east-1'):
    """CloudWatch Logs에서 성능 메트릭 추출"""
    logs = boto3.client('logs', region_name=region)
    
    metrics = {
        'db_download_duration': None,
        'blast_duration': None,
        'total_duration': None,
        'start_time': None,
        'end_time': None
    }
    
    try:
        response = logs.filter_log_events(
            logGroupName=log_group,
            filterPattern='duration'
        )
        
        for event in response['events']:
            message = event['message']
            
            # DB 다운로드 시간
            match = re.search(r'DB download duration: (\d+) seconds', message)
            if match:
                metrics['db_download_duration'] = int(match.group(1))
            
            # BLAST 실행 시간
            match = re.search(r'BLAST execution duration: (\d+) seconds', message)
            if match:
                metrics['blast_duration'] = int(match.group(1))
            
            # 총 소요 시간
            match = re.search(r'Total duration: (\d+) seconds', message)
            if match:
                metrics['total_duration'] = int(match.group(1))
            
            # 시작/종료 시간
            if 'Job started at' in message:
                metrics['start_time'] = event['timestamp']
            if 'Job completed at' in message:
                metrics['end_time'] = event['timestamp']
    
    except Exception as e:
        print(f"Error extracting metrics from {log_group}: {e}")
    
    return metrics

def compare_scenarios(region='us-east-1'):
    """3가지 시나리오 성능 비교"""
    scenarios = {
        'EFS': '/blast-perf-test/batch/efs',
        'Lustre': '/blast-perf-test/batch/lustre',
        'S3': '/blast-perf-test/batch/s3'
    }
    
    results = {}
    
    for name, log_group in scenarios.items():
        print(f"\n분석 중: {name}")
        metrics = extract_metrics_from_logs(log_group, region)
        results[name] = metrics
        
        print(f"  DB 다운로드: {metrics['db_download_duration'] or 'N/A'} 초")
        print(f"  BLAST 실행: {metrics['blast_duration'] or 'N/A'} 초")
        print(f"  총 소요 시간: {metrics['total_duration'] or 'N/A'} 초")
    
    # 비교 테이블 출력
    print("\n" + "="*80)
    print("성능 비교 결과")
    print("="*80)
    print(f"{'시나리오':<15} {'DB 다운로드':<15} {'BLAST 실행':<15} {'총 시간':<15}")
    print("-"*80)
    
    for name, metrics in results.items():
        db_time = f"{metrics['db_download_duration']}s" if metrics['db_download_duration'] else "0s (사전로드)"
        blast_time = f"{metrics['blast_duration']}s" if metrics['blast_duration'] else "N/A"
        total_time = f"{metrics['total_duration']}s" if metrics['total_duration'] else "N/A"
        
        print(f"{name:<15} {db_time:<15} {blast_time:<15} {total_time:<15}")
    
    # 성능 개선율 계산
    if results['S3']['total_duration'] and results['Lustre']['total_duration']:
        improvement = ((results['S3']['total_duration'] - results['Lustre']['total_duration']) 
                      / results['S3']['total_duration'] * 100)
        print(f"\nLustre vs S3 성능 개선: {improvement:.1f}%")
    
    if results['S3']['total_duration'] and results['EFS']['total_duration']:
        improvement = ((results['S3']['total_duration'] - results['EFS']['total_duration']) 
                      / results['S3']['total_duration'] * 100)
        print(f"EFS vs S3 성능 개선: {improvement:.1f}%")
    
    return results

if __name__ == '__main__':
    import sys
    region = sys.argv[1] if len(sys.argv) > 1 else 'us-east-1'
    compare_scenarios(region)
